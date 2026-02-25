# frozen_string_literal: true

# name: discourse-no-likes
# about: Phantom reactions in selected categories — visible in UI, zero stat impact
# version: 0.1
# authors: TripleU

enabled_site_setting :discourse_no_likes_enabled

module ::DiscourseNoLikes
  PLUGIN_NAME = "discourse-no-likes"

  # SQL: count real likes received by a user, excluding restricted categories
  LIKES_RECEIVED_SQL = <<~SQL.freeze
    SELECT COUNT(*)
      FROM post_actions  pa
      JOIN posts         p  ON p.id  = pa.post_id   AND p.deleted_at  IS NULL
      JOIN topics        t  ON t.id  = p.topic_id   AND t.deleted_at  IS NULL
     WHERE p.user_id              = %{uid}
       AND pa.post_action_type_id = %{like_type}
       AND pa.deleted_at          IS NULL
       AND t.category_id NOT IN (%{restricted})
  SQL

  # SQL: count real likes given by a user, excluding restricted categories
  LIKES_GIVEN_SQL = <<~SQL.freeze
    SELECT COUNT(*)
      FROM post_actions  pa
      JOIN posts         p  ON p.id  = pa.post_id   AND p.deleted_at  IS NULL
      JOIN topics        t  ON t.id  = p.topic_id   AND t.deleted_at  IS NULL
     WHERE pa.user_id             = %{uid}
       AND pa.post_action_type_id = %{like_type}
       AND pa.deleted_at          IS NULL
       AND t.category_id NOT IN (%{restricted})
  SQL

  def self.restricted_category_ids
    SiteSetting.no_reactions_category_ids.to_s.split("|").map(&:to_i).reject(&:zero?)
  end

  def self.restricted?(post)
    ids = restricted_category_ids
    ids.any? && ids.include?(post&.topic&.category_id)
  end

  # Run an excluded-count query; returns nil if no categories are restricted
  def self.count_excluding_restricted(sql_template, uid:)
    restricted = restricted_category_ids
    return nil if restricted.empty?

    like_type = PostActionType.types[:like]
    sql = sql_template % {
      uid:        uid.to_i,
      like_type:  like_type,
      restricted: restricted.map(&:to_i).join(","),
    }
    DB.query_single(sql).first.to_i
  end
end

after_initialize do
  require_relative "app/models/discourse_no_likes/phantom_reaction"

  # ── 1. Override UserStat.update_likes_received! ────────────────────────────
  # Discourse calls this to (re)calculate how many likes a user's posts received.
  # We shadow-replace it so restricted-category likes are silently excluded.
  if UserStat.respond_to?(:update_likes_received!)
    UserStat.singleton_class.prepend(
      Module.new do
        def update_likes_received!(user_id)
          count = DiscourseNoLikes.count_excluding_restricted(
            DiscourseNoLikes::LIKES_RECEIVED_SQL, uid: user_id
          )
          return super(user_id) if count.nil?   # no restricted cats — normal path

          DB.exec(
            "UPDATE user_stats SET likes_received = :c WHERE user_id = :u",
            c: count, u: user_id.to_i,
          )
        end
      end
    )
  end

  # ── 2. Override likes_given recalculation (try both known method names) ─────
  %i[update_likes_given! update_likes_given_for].each do |meth|
    next unless UserStat.respond_to?(meth)

    UserStat.singleton_class.prepend(
      Module.new do
        define_method(meth) do |user_or_id|
          uid   = user_or_id.is_a?(Integer) ? user_or_id : user_or_id.id
          count = DiscourseNoLikes.count_excluding_restricted(
            DiscourseNoLikes::LIKES_GIVEN_SQL, uid: uid
          )
          return super(user_or_id) if count.nil?

          DB.exec(
            "UPDATE user_stats SET likes_given = :c WHERE user_id = :u",
            c: count, u: uid,
          )
        end
      end
    )
    break  # only patch once
  end

  # ── 3. on(:post_action_created): record phantom + nuke notification ─────────
  # This fires after a PostAction (like) is committed to the DB.
  # Responsibilities:
  #   a) Store in phantom table (audit trail)
  #   b) Kill the "you were liked" notification — receiver never knows
  #   c) Force re-run of our patched stat methods as safety net
  #      (handles Discourse versions that use inline SQL instead of the class method)
  on(:post_action_created) do |post_action|
    next unless post_action.post_action_type_id == PostActionType.types[:like]
    next unless (post = post_action.post)
    next unless DiscourseNoLikes.restricted?(post)

    # (a) Audit trail
    ::DiscourseNoLikes::PhantomReaction.create!(
      post_id:       post.id,
      user_id:       post_action.user_id,
      category_id:   post.topic.category_id,
      reaction_type: "like",
    )

    # (b) Suppress notification
    Notification
      .where(
        user_id:           post.user_id,
        notification_type: Notification.types[:liked],
        topic_id:          post.topic_id,
        post_number:       post.post_number,
      )
      .where("created_at >= ?", 30.seconds.ago)
      .destroy_all

    # (c) Safety-net recalc via our patched methods
    UserStat.update_likes_received!(post.user_id) if UserStat.respond_to?(:update_likes_received!)

    %i[update_likes_given! update_likes_given_for].each do |m|
      if UserStat.respond_to?(m)
        UserStat.public_send(m, post_action.user_id)
        break
      end
    end
  end

  # ── 4. discourse-reactions: record non-heart emoji reactions in phantom table ─
  # Heart reactions create a PostAction (handled above).
  # Pure emoji reactions (non-heart) only create a DiscourseReactions::ReactionUser;
  # they don't touch likes_given/received, so no stat reversal is needed here —
  # we just log them to the phantom table for completeness.
  if defined?(DiscourseReactions::ReactionUser)
    DiscourseReactions::ReactionUser.class_eval do
      after_create :dnl_record_phantom_emoji

      private

      def dnl_record_phantom_emoji
        return unless DiscourseNoLikes.restricted?(post)

        main_id = (DiscourseReactions::Reaction.main_reaction_id.to_s rescue "heart")
        rv      = reaction&.reaction_value.to_s
        return if rv == main_id   # already handled by PostAction hook

        ::DiscourseNoLikes::PhantomReaction.create!(
          post_id:       post_id,
          user_id:       user_id,
          category_id:   post.topic.category_id,
          reaction_type: rv,
        )
      end
    end
  end
end
