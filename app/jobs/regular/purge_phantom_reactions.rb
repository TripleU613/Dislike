# frozen_string_literal: true

module Jobs
  class PurgePhantomReactions < ::Jobs::Base
    def execute(_args)
      restricted = DiscourseNoLikes.restricted_category_ids
      return if restricted.empty?

      like_type     = PostActionType.types[:like]
      restricted_str = restricted.map(&:to_i).join(",")

      # 1. Back-fill the audit table with any existing phantom likes not yet recorded
      DB.exec(<<~SQL)
        INSERT INTO discourse_no_likes_phantoms
                    (post_id, user_id, category_id, reaction_type, created_at, updated_at)
        SELECT  pa.post_id, pa.user_id, t.category_id, 'like', NOW(), NOW()
          FROM  post_actions pa
          JOIN  posts  p ON p.id = pa.post_id AND p.deleted_at IS NULL
          JOIN  topics t ON t.id = p.topic_id AND t.deleted_at IS NULL
         WHERE  pa.post_action_type_id = #{like_type}
           AND  pa.deleted_at IS NULL
           AND  t.category_id IN (#{restricted_str})
        ON CONFLICT DO NOTHING
      SQL

      # 2. Collect every user whose stats may be wrong (gave OR received a like
      #    in a restricted category)
      affected_ids =
        DB
          .query_single(<<~SQL)
            SELECT DISTINCT u FROM (
              SELECT p.user_id AS u
                FROM post_actions pa
                JOIN posts  p ON p.id = pa.post_id AND p.deleted_at IS NULL
                JOIN topics t ON t.id = p.topic_id AND t.deleted_at IS NULL
               WHERE pa.post_action_type_id = #{like_type}
                 AND pa.deleted_at IS NULL
                 AND t.category_id IN (#{restricted_str})
              UNION ALL
              SELECT pa.user_id AS u
                FROM post_actions pa
                JOIN posts  p ON p.id = pa.post_id AND p.deleted_at IS NULL
                JOIN topics t ON t.id = p.topic_id AND t.deleted_at IS NULL
               WHERE pa.post_action_type_id = #{like_type}
                 AND pa.deleted_at IS NULL
                 AND t.category_id IN (#{restricted_str})
            ) sub
          SQL
          .uniq

      return if affected_ids.empty?

      # 3. Recalculate likes_given and likes_received for every affected user,
      #    using counts that exclude restricted categories
      affected_ids.each do |uid|
        likes_received =
          DB
            .query_single(
              DiscourseNoLikes::LIKES_RECEIVED_SQL %
                { uid: uid.to_i, like_type: like_type, restricted: restricted_str },
            )
            .first
            .to_i

        likes_given =
          DB
            .query_single(
              DiscourseNoLikes::LIKES_GIVEN_SQL %
                { uid: uid.to_i, like_type: like_type, restricted: restricted_str },
            )
            .first
            .to_i

        DB.exec(
          "UPDATE user_stats SET likes_received = :lr, likes_given = :lg WHERE user_id = :uid",
          lr: likes_received,
          lg: likes_given,
          uid: uid,
        )
      end

      Rails.logger.info(
        "DiscourseNoLikes: purge complete — recalculated stats for #{affected_ids.size} users",
      )
    end
  end
end
