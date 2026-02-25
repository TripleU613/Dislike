# frozen_string_literal: true

# name: dislike
# about: Phantom reactions in selected categories — visible in UI, zero stat impact
# meta_topic_id: TODO
# version: 0.2.0
# authors: TripleU
# url: https://github.com/TripleU613/Dislike
# required_version: 2.7.0

enabled_site_setting :discourse_no_likes_enabled

module ::DiscourseNoLikes
  PLUGIN_NAME = "dislike"

  # SQL: count real likes received by a user, excluding restricted categories
  LIKES_RECEIVED_SQL = <<~SQL.freeze
    SELECT COUNT(*)
      FROM post_actions  pa
      JOIN posts         p  ON p.id  = pa.post_id   AND p.deleted_at IS NULL
      JOIN topics        t  ON t.id  = p.topic_id   AND t.deleted_at IS NULL
     WHERE p.user_id              = %{uid}
       AND pa.post_action_type_id = %{like_type}
       AND pa.deleted_at          IS NULL
       AND t.category_id NOT IN (%{restricted})
  SQL

  # SQL: count real likes given by a user, excluding restricted categories
  LIKES_GIVEN_SQL = <<~SQL.freeze
    SELECT COUNT(*)
      FROM post_actions  pa
      JOIN posts         p  ON p.id  = pa.post_id   AND p.deleted_at IS NULL
      JOIN topics        t  ON t.id  = p.topic_id   AND t.deleted_at IS NULL
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
end

require_relative "lib/discourse_no_likes/engine"

after_initialize do
  # ── How stat updates actually work in this Discourse version ─────────────────
  # UserAction.log! is called when a like is created/destroyed.
  # It calls UserAction.update_like_count(user_id, action_type, delta) which does
  # raw SQL increments on user_stats.likes_given / likes_received.
  # We intercept log! and remove_action! to set a thread-local flag, then gate
  # update_like_count on that flag — so restricted-category likes never touch stats.

  # ── 1. Gate update_like_count with a thread-local flag ───────────────────────
  UserAction.singleton_class.prepend(
    Module.new do
      def update_like_count(user_id, action_type, delta)
        return if Thread.current[:dnl_skip_like_stat]
        super
      end
    end,
  )

  # ── 2. Set the flag in log! (like created) ───────────────────────────────────
  UserAction.singleton_class.prepend(
    Module.new do
      def log!(hash, transaction_opts = {})
        is_like = [UserAction::LIKE, UserAction::WAS_LIKED].include?(hash[:action_type])
        if is_like && DiscourseNoLikes.restricted_category_ids.any?
          topic = Topic.find_by(id: hash[:target_topic_id])
          Thread.current[:dnl_skip_like_stat] =
            topic && DiscourseNoLikes.restricted_category_ids.include?(topic.category_id)
        end
        super(hash, transaction_opts)
      ensure
        Thread.current[:dnl_skip_like_stat] = nil if is_like
      end
    end,
  )

  # ── 3. Set the flag in remove_action! (like removed / unlike) ────────────────
  # Without this, unliking a phantom like would decrement stats that were never
  # incremented, sending them negative.
  UserAction.singleton_class.prepend(
    Module.new do
      def remove_action!(hash)
        is_like = [UserAction::LIKE, UserAction::WAS_LIKED].include?(hash[:action_type])
        if is_like && DiscourseNoLikes.restricted_category_ids.any?
          Thread.current[:dnl_skip_like_stat] =
            Topic
              .where(
                id: hash[:target_topic_id],
                category_id: DiscourseNoLikes.restricted_category_ids,
              )
              .exists?
        end
        super(hash)
      ensure
        Thread.current[:dnl_skip_like_stat] = nil if is_like
      end
    end,
  )

  # ── 4. Audit trail + suppress "liked" notification ───────────────────────────
  on(:post_action_created) do |post_action|
    next unless post_action.post_action_type_id == PostActionType.types[:like]
    next unless (post = post_action.post)
    next unless DiscourseNoLikes.restricted?(post)

    DiscourseNoLikes::PhantomReaction.create!(
      post_id: post.id,
      user_id: post_action.user_id,
      category_id: post.topic.category_id,
      reaction_type: "like",
    )

    Notification
      .where(
        user_id: post.user_id,
        notification_type: Notification.types[:liked],
        topic_id: post.topic_id,
        post_number: post.post_number,
      )
      .where("created_at >= ?", 30.seconds.ago)
      .destroy_all
  end

  # ── 5. discourse-reactions: record non-heart emoji reactions ─────────────────
  if defined?(DiscourseReactions::ReactionUser)
    DiscourseReactions::ReactionUser.class_eval do
      after_create :dnl_record_phantom_emoji

      private

      def dnl_record_phantom_emoji
        return unless DiscourseNoLikes.restricted?(post)
        main_id = (DiscourseReactions::Reaction.main_reaction_id.to_s rescue "heart")
        rv = reaction&.reaction_value.to_s
        return if rv == main_id

        DiscourseNoLikes::PhantomReaction.create!(
          post_id: post_id,
          user_id: user_id,
          category_id: post.topic.category_id,
          reaction_type: rv,
        )
      end
    end
  end

  # ── 6. Retroactive purge trigger ─────────────────────────────────────────────
  # Toggle "purge_phantom_likes_now" in Admin → Settings → Plugins to kick off
  # a background job that recalculates stats for all affected users.
  # The setting resets to false automatically after enqueuing.
  on(:site_setting_changed) do |name, _old, new_val|
    if name == :purge_phantom_likes_now && new_val == true
      Jobs.enqueue(:purge_phantom_reactions)
      SiteSetting.purge_phantom_likes_now = false
    end
  end
end
