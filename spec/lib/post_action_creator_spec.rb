# frozen_string_literal: true

RSpec.describe PostActionCreator do
  fab!(:admin) { Fabricate(:admin) }
  fab!(:user) { Fabricate(:user) }
  fab!(:post) { Fabricate(:post) }
  let(:like_type_id) { PostActionType.types[:like] }

  before { Group.refresh_automatic_groups! }

  describe "rate limits" do
    before { RateLimiter.enable }

    use_redis_snapshotting

    it "limits redo/undo" do
      PostActionCreator.like(user, post)
      PostActionDestroyer.destroy(user, post, :like)
      PostActionCreator.like(user, post)
      PostActionDestroyer.destroy(user, post, :like)

      expect { PostActionCreator.like(user, post) }.to raise_error(RateLimiter::LimitExceeded)
    end
  end

  describe "messaging" do
    it "doesn't generate title longer than 255 characters" do
      topic =
        Fabricate(
          :topic,
          title:
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nunc sit amet rutrum neque. Pellentesque suscipit vehicula facilisis. Phasellus lacus sapien, aliquam nec convallis sit amet, vestibulum laoreet ante. Curabitur et pellentesque tortor. Donec non.",
        )
      post = Fabricate(:post, topic: topic)

      expect(PostActionCreator.notify_user(user, post, "WAT")).to be_success
    end

    it "creates a pm to mods if selected" do
      result = PostActionCreator.notify_moderators(user, post, "this is my special message")
      expect(result).to be_success
      post_action = result.post_action
      expect(post_action.related_post).to be_present
      expect(post_action.related_post.raw).to include("this is my special message")
    end

    it "sends an pm to user if selected" do
      result = PostActionCreator.notify_user(user, post, "another special message")
      expect(result).to be_success
      post_action = result.post_action
      expect(post_action.related_post).to be_present
      expect(post_action.related_post.raw).to include("another special message")
    end
  end

  describe "perform" do
    it "creates a post action" do
      result = PostActionCreator.new(user, post, like_type_id).perform
      expect(result.success).to eq(true)
      expect(result.post_action).to be_present
      expect(result.post_action.user).to eq(user)
      expect(result.post_action.post).to eq(post)
      expect(result.post_action.post_action_type_id).to eq(like_type_id)

      # also test double like
      result = PostActionCreator.new(user, post, like_type_id).perform
      expect(result.success).not_to eq(true)
      expect(result.forbidden).to eq(true)
      expect(result.errors.full_messages.join).to eq(I18n.t("action_already_performed"))
    end

    it "notifies subscribers" do
      expect(post.reload.like_count).to eq(0)

      messages =
        MessageBus.track_publish { PostActionCreator.new(user, post, like_type_id).perform }

      message = messages.find { |msg| msg.data[:type] === :liked }.data
      expect(message).to be_present
      expect(message[:type]).to eq(:liked)
      expect(message[:likes_count]).to eq(1)
      expect(message[:user_id]).to eq(user.id)
    end

    it "notifies updated topic stats to subscribers" do
      topic = Fabricate(:topic)
      post = Fabricate(:post, topic: topic)

      expect(post.reload.like_count).to eq(0)

      messages =
        MessageBus.track_publish("/topic/#{topic.id}") do
          PostActionCreator.new(user, post, like_type_id).perform
        end

      stats_message = messages.select { |msg| msg.data[:type] == :stats }.first
      expect(stats_message).to be_present
      expect(stats_message.data[:like_count]).to eq(1)
    end

    it "does not create an invalid post action" do
      result = PostActionCreator.new(user, nil, like_type_id).perform
      expect(result.failed?).to eq(true)
    end

    it "does not create a double like notification" do
      PostActionNotifier.enable
      post.user.user_option.update!(
        like_notification_frequency: UserOption.like_notification_frequency_type[:always],
      )

      expect(PostActionCreator.new(user, post, like_type_id).perform.success).to eq(true)
      expect(PostActionDestroyer.new(user, post, like_type_id).perform.success).to eq(true)
      expect(PostActionCreator.new(user, post, like_type_id).perform.success).to eq(true)

      notification = Notification.last
      notification_data = JSON.parse(notification.data)
      expect(notification_data["display_username"]).to eq(user.username)
      expect(notification_data["username2"]).to eq(nil)
    end

    it "does not create a notification if silent mode is enabled" do
      PostActionNotifier.enable

      expect(PostActionCreator.new(user, post, like_type_id, silent: true).perform.success).to eq(
        true,
      )

      expect(Notification.where(notification_type: Notification.types[:liked]).exists?).to eq(false)
    end

    it "triggers the right flag events" do
      events = DiscourseEvent.track_events { PostActionCreator.create(user, post, :inappropriate) }
      event_names = events.map { |event| event[:event_name] }
      expect(event_names).to include(:flag_created)
      expect(event_names).not_to include(:like_created)
    end

    it "triggers the right like events" do
      events = DiscourseEvent.track_events { PostActionCreator.create(user, post, :like) }
      event_names = events.map { |event| event[:event_name] }
      expect(event_names).to include(:like_created)
      expect(event_names).not_to include(:flag_created)
    end

    it "sends the right event arguments" do
      events = DiscourseEvent.track_events { PostActionCreator.create(user, post, :like) }
      event = events.find { |e| e[:event_name] == :like_created }
      expect(event.present?).to eq(true)
      expect(event[:params].first).to be_instance_of(PostAction)
      expect(event[:params].second).to be_instance_of(PostActionCreator)
    end
  end

  describe "flags" do
    it "will create a reviewable if one does not exist" do
      result = PostActionCreator.create(user, post, :inappropriate)
      expect(result.success?).to eq(true)

      reviewable = result.reviewable
      expect(reviewable).to be_pending
      expect(reviewable.created_by).to eq(user)
      expect(reviewable.type).to eq("ReviewableFlaggedPost")
      expect(reviewable.target_created_by_id).to eq(post.user_id)

      expect(reviewable.reviewable_scores.count).to eq(1)
      score = reviewable.reviewable_scores.find_by(user: user)
      expect(score).to be_present
      expect(score.reviewed_by).to be_blank
      expect(score.reviewed_at).to be_blank
    end

    describe "Auto hide spam flagged posts" do
      before do
        user.trust_level = TrustLevel[3]
        post.user.trust_level = TrustLevel[0]
        SiteSetting.high_trust_flaggers_auto_hide_posts = true
      end

      it "hides the post when the flagger is a TL3 user and the poster is a TL0 user" do
        PostActionCreator.create(user, post, :spam)

        expect(post.hidden?).to eq(true)
      end

      it "does not hide the post if the setting is disabled" do
        SiteSetting.high_trust_flaggers_auto_hide_posts = false

        PostActionCreator.create(user, post, :spam)

        expect(post.hidden?).to eq(false)
      end

      it "sets the force_review field" do
        result = PostActionCreator.create(user, post, :spam)

        reviewable = result.reviewable

        expect(reviewable.force_review).to eq(true)
      end
    end

    context "with existing reviewable" do
      let!(:reviewable) do
        PostActionCreator.create(Fabricate(:user), post, :inappropriate).reviewable
      end

      it "appends to an existing reviewable if exists" do
        result = PostActionCreator.create(user, post, :inappropriate)
        expect(result.success?).to eq(true)

        expect(result.reviewable).to eq(reviewable)
        expect(reviewable.reviewable_scores.count).to eq(2)
        score = reviewable.reviewable_scores.find_by(user: user)
        expect(score).to be_present
        expect(score.reviewed_by).to be_blank
        expect(score.reviewed_at).to be_blank
      end

      describe "When the post was already reviewed by staff" do
        before { reviewable.perform(admin, :ignore_and_do_nothing) }

        it "fails because the post was recently reviewed" do
          freeze_time 10.seconds.from_now
          result = PostActionCreator.create(user, post, :inappropriate)

          expect(result.success?).to eq(false)
        end

        it "succeeds with other flag action types" do
          freeze_time 10.seconds.from_now
          _spam_result = PostActionCreator.create(user, post, :spam)

          expect(reviewable.reload.pending?).to eq(true)
        end

        it "fails when other flag action types are open" do
          freeze_time 10.seconds.from_now
          _spam_result = PostActionCreator.create(user, post, :spam)

          inappropriate_result = PostActionCreator.create(Fabricate(:user), post, :inappropriate)

          reviewable.reload

          expect(inappropriate_result.success?).to eq(false)
          expect(reviewable.pending?).to eq(true)
          expect(reviewable.reviewable_scores.select(&:pending?).count).to eq(1)
        end

        it "successfully flags the post if it was reviewed more than 24 hours ago" do
          reviewable.update!(updated_at: 25.hours.ago)
          post.last_version_at = 30.hours.ago

          result = PostActionCreator.create(user, post, :inappropriate)

          expect(result.success?).to eq(true)
          expect(result.reviewable).to be_present
        end

        it "successfully flags the post if it was edited after being reviewed" do
          reviewable.update!(updated_at: 10.minutes.ago)
          post.last_version_at = 1.minute.ago

          result = PostActionCreator.create(user, post, :inappropriate)

          expect(result.success?).to eq(true)
          expect(result.reviewable).to be_present
        end
      end
    end
  end

  describe "take_action" do
    before { PostActionCreator.create(Fabricate(:user), post, :inappropriate) }

    it "will agree with the old reviewable" do
      reviewable =
        PostActionCreator
          .new(Fabricate(:moderator), post, PostActionType.types[:spam], take_action: true)
          .perform
          .reviewable
      scores = reviewable.reviewable_scores
      expect(scores[0]).to be_agreed
      expect(scores[1]).to be_agreed
      expect(reviewable.reload).to be_approved
    end
  end

  describe "queue_for_review" do
    it "fails if the user is not a staff member" do
      creator =
        PostActionCreator.new(
          user,
          post,
          PostActionType.types[:notify_moderators],
          queue_for_review: true,
        )
      result = creator.perform

      expect(result.success?).to eq(false)
    end

    it "creates a new reviewable and hides the post" do
      result = build_creator.perform

      expect(result.success?).to eq(true)

      score = result.reviewable.reviewable_scores.last
      expect(score.reason).to eq("queued_by_staff")
      expect(post.reload.hidden?).to eq(true)
    end

    it "hides the topic even if it has replies" do
      Fabricate(:post, topic: post.topic)

      _result = build_creator.perform

      expect(post.topic.reload.visible?).to eq(false)
    end

    def build_creator
      PostActionCreator.new(
        admin,
        post,
        PostActionType.types[:notify_moderators],
        queue_for_review: true,
      )
    end
  end
end
