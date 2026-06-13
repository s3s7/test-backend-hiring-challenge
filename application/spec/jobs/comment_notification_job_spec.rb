require 'rails_helper'

RSpec.describe CommentNotificationJob, type: :job do
  let(:user) { User.create!(name: 'Alice', email: "job-#{SecureRandom.hex(3)}@example.com", password: 'pw') }
  let(:post_record) { Post.create!(title: 't', content: 'c', user: user) }
  let(:comment) { Comment.create!(name: 'n', content: 'c', post: post_record, user: user) }

  describe '宣言（要件1 / 2）' do
    it 'retry_on StandardError を宣言している' do
      handlers = described_class.rescue_handlers
      retry_entry = handlers.find { |klass, _| klass == 'StandardError' }
      expect(retry_entry).to be_present, '`retry_on StandardError` が宣言されていない'
    end

    it 'discard_on ActiveJob::DeserializationError を宣言している' do
      handlers = described_class.rescue_handlers
      discard_entry = handlers.find { |klass, _| klass == 'ActiveJob::DeserializationError' }
      expect(discard_entry).to be_present, '`discard_on ActiveJob::DeserializationError` が宣言されていない'
    end
  end

  describe 'キュー投入（要件3 / 6 統合）' do
    include ActiveJob::TestHelper

    it 'Comment#create の after_commit でキューに 1 件入る' do
      expect {
        Comment.create!(name: 'n', content: 'c', post: post_record, user: user)
      }.to have_enqueued_job(described_class).on_queue('default').exactly(:once)
    end

    it 'トランザクションが rollback すると enqueue されない（dual-write 防止）' do
      expect {
        ActiveRecord::Base.transaction do
          Comment.create!(name: 'n', content: 'c', post: post_record, user: user)
          raise ActiveRecord::Rollback
        end
      }.not_to have_enqueued_job(described_class)
    end
  end

  describe '冪等性（要件5）' do
    before { comment } # 通知対象を確定

    it '同じ comment_id で 2 回実行しても notifications_count は 1 だけ増える' do
      expect {
        described_class.perform_now(comment.id)
        described_class.perform_now(comment.id) # 2 回目
      }.to change { post_record.reload.notifications_count }.by(1)
    end

    it '何度実行しても CommentNotification 行は 1 つしか残らない' do
      3.times { described_class.perform_now(comment.id) }

      expect(CommentNotification.where(comment_id: comment.id).count).to eq(1)
    end

    it '2 回目の実行はスキップログを出して例外を投げない' do
      described_class.perform_now(comment.id)

      allow(Rails.logger).to receive(:info).and_call_original
      expect { described_class.perform_now(comment.id) }.not_to raise_error
      expect(Rails.logger).to have_received(:info).with(/already notified, skipped/).at_least(:once)
    end
  end
end
