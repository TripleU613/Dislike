# discourse-no-likes

A Discourse plugin that makes reactions in selected categories **phantom** — users can still react and see reaction counts, but the reactions have zero effect on stats, profiles, or leaderboards.

## What it does

| Thing | Behaviour |
|---|---|
| Reaction button | Works normally, count shows on post |
| `likes_received` (author's profile) | Not incremented |
| `likes_given` (reactor's profile) | Not incremented |
| "You were liked" notification | Suppressed |
| Trust level calculations | Unaffected (based on `likes_received`) |
| Leaderboard / directory | Unaffected (based on `user_stats`) |
| Audit trail | Stored in `discourse_no_likes_phantoms` table |

## Installation

Add to your `app.yml` under `hooks > after_code`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/TripleU613/Dislike.git discourse-no-likes
```

Then rebuild: `./launcher rebuild app`

### Dev / quick install (symlink, no rebuild)

```bash
# On host
ln -sfn /var/discourse/shared/standalone/plugins/discourse-no-likes \
        /var/www/discourse/plugins/discourse-no-likes

# Inside container
docker exec app bash -c 'su discourse -s /bin/bash -c \
  "cd /var/www/discourse && bundle exec rake db:migrate"'

docker exec app sv restart unicorn
```

## Configuration

**Admin → Settings → Plugins → discourse-no-likes**

| Setting | Type | Description |
|---|---|---|
| `discourse_no_likes_enabled` | bool | Master on/off switch |
| `no_reactions_category_ids` | category picker | Categories where reactions are phantom |

Select one or more categories from the dropdown — no IDs needed.

## How it works

1. Reactions are **stored normally** in `post_actions` / `DiscourseReactions::ReactionUser` so the UI renders them correctly.
2. `UserStat.update_likes_received!` and `update_likes_given!` are overridden to exclude posts in restricted categories from their SQL count — so every recalculation (create, destroy, periodic jobs) naturally gives the right number.
3. The `on(:post_action_created)` event hook suppresses the "liked" notification and fires a safety-net recalculation.
4. A separate `discourse_no_likes_phantoms` table records every phantom reaction for auditing.

## Querying the phantom table

```ruby
# Rails console inside container
DiscourseNoLikes::PhantomReaction.where(category_id: 5).count
DiscourseNoLikes::PhantomReaction.where(user_id: User.find_by_username("alice").id)
```

## Compatibility

- Discourse with `discourse-reactions` plugin installed (emoji reactions + heart)
- Falls back gracefully if `discourse-reactions` is not present
