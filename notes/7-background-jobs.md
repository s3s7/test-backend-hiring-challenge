# 第7問: バックグラウンドジョブ（ActiveJob + Sidekiq）

## 再現（現象の確認）

旧実装の `CommentsController#create` は `@comment.save` 成功後に `CommentNotificationJob.perform_later(@comment.id)` を直接呼び、`CommentNotificationJob#perform` は `Post.find(...).increment!(:notifications_count)` を 1 行で叩いていた。次の壊れ方が同居している:

- 再実行ポリシー宣言なし: 一時障害（Redis 切断・DB タイムアウト）で 1 回失敗するとそのまま落ちる。リトライ後の挙動が「Sidekiq 全体のデフォルト 25 回」だけに支配され、ジョブ単位の意図がコードに残らない。
- 例外チャンネルの未分離: 削除済 Comment を引数に呼ばれた時の `ActiveJob::DeserializationError` も、本物の障害も、同じ rescue 経路に流れる（=「永久リトライしてはいけない例外」が永久リトライされる）。
- dual-write: controller の `save` でコミット直後に enqueue するため「DB は保存済みなのに enqueue 失敗」「enqueue 成功後に外側のトランザクションが rollback」のいずれもアプリ整合性を壊す。
- 非冪等: at-least-once 配送下では同じ `comment_id` で複数回 `perform` され得るが、`increment!` は無条件加算なので `notifications_count` が二重カウントされる。

「なぜ二重実行が起こり得るか」は ActiveJob + Sidekiq の配送セマンティクスそのもの:

- Sidekiq のリトライ（`retry_on` attempts 内）で同じジョブが再投入される。
- ワーカが job を pop した直後にプロセス強制終了 → Sidekiq の reliable fetch / super_fetch / ack 未送出により別ワーカで再 pop。
- 同じトピックに対する複数 producer（after_commit + 運用 rake で手動投入等）。

これらは設計で完全に消すのが難しく、「at-least-once 前提で副作用側を冪等化する」のが正攻法。

## 原因

- ActiveJob の `retry_on` / `discard_on` をジョブに宣言する「真実の置き場所」がなかった。Sidekiq の retry 設定だけに頼っていて、ジョブ側のコードを読んでも再実行ポリシーが分からない。
- 「DB と外部副作用（=ジョブ投入）を同じトランザクション境界で扱えない」という分散システム上の基本制約を、Rails の after_commit / outbox いずれでも明示していなかった（=暗黙に dual-write を許容）。
- at-least-once 配送を前提にしたガード（= 同じイベントが複数回到着しても結果が変わらない構造）が無かった。`perform` 自体は単純な副作用列で、何度叩いても同じ結果にはならない作りになっていた。

## 対応

### 1. リトライ / 廃棄ポリシーをジョブに宣言（要件1, 2）

```ruby
class CommentNotificationJob < ApplicationJob
  queue_as :default

  retry_on StandardError, attempts: 5, wait: :polynomially_longer

  discard_on ActiveJob::DeserializationError do |job, error|
    Rails.logger.error("[CommentNotificationJob] discarded: #{error.class} args=#{job.arguments.inspect}")
  end
end
```

- `retry_on StandardError` で一時障害に多項式バックオフ。5 回失敗すると Sidekiq の Dead Set へ自動移送される（後述）。
- `discard_on ActiveJob::DeserializationError` で「Comment が既に消えているケース」を永久リトライから切り離す。discard 時に `Rails.logger.error` でジョブ引数を残し、後追い調査の出発点を作る。

### 2. Dead Set 通知（要件4）

`config/initializers/sidekiq.rb` で `dead_max_jobs = 1_000`、`dead_timeout_in_seconds = 180 days` を明示。Sidekiq は最大リトライ超過のジョブを自動的に Dead Set に積み、`Rails.logger.error` への書き出しを `discard_on` ブロックでも併発させているので、運用上は「Dead Set 件数の監視 + アプリログの ERROR 監視」の二段構えになる。Slack / Sentry 等への配線は本問のスコープ外（インフラ側）。

### 3. トランザクショナルな enqueue（要件3, 6）

controller の create 直後の `perform_later` を撤去し、`Comment` モデルの `after_commit on: :create` に移した:

```ruby
class Comment < ApplicationRecord
  after_commit on: :create do
    CommentNotificationJob.perform_later(id)
  end
end
```

- `after_commit` は「DB トランザクションが COMMIT した直後」のフックなので、外側で rollback したケースでは絶対に enqueue が走らない（= dual-write の「DB は戻したのにジョブだけ進む」を消す）。
- 一方で「コミット済 → enqueue 直前にプロセス落ち」は依然残る（=これがいわゆる Outbox パターンで解く問題）。本問では Outbox 導入はオーバーキルと判断し、「after_commit + ジョブ側の冪等性ガード」で実用上の整合性を確保。

### 4. 冪等性ガード（要件5）

新規テーブル `comment_notifications(comment_id UNIQUE)` を導入して、ジョブの先頭で `create!` させる。

```ruby
def perform(comment_id)
  ApplicationRecord.transaction do
    CommentNotification.create!(comment_id: comment_id)
    comment = Comment.find(comment_id)
    Post.where(id: comment.post_id).update_all("notifications_count = notifications_count + 1")
    Rails.logger.info("[CommentNotificationJob] notified post=#{comment.post_id} comment=#{comment_id}")
  end
rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
  Rails.logger.info(
    "[CommentNotificationJob] already notified, skipped (comment=#{comment_id}, #{e.class})"
  )
end
```

- UNIQUE 制約は MySQL 側で担保。2 回目以降の `create!` は `ActiveRecord::RecordNotUnique` か `ActiveRecord::RecordInvalid`（uniqueness validation 経由）で短絡し、副作用ゼロでリターン。
- 1 トランザクションに「ガード行の挿入」と「カウンタ加算」を入れているのが要点: 加算側で例外が出れば挿入もロールバックされるので、次回の再実行で「ガード行は入ってるのに加算は未反映」という宙ぶらりん状態を作らない。
- カウンタは `update_all("notifications_count = notifications_count + 1")` で 1 文の UPDATE に落としている（`increment!` は select → update の 2 文になり、競合下で値が壊れる）。

## 判断・トレードオフ

### 真実のリトライ設定は ActiveJob 側に置く

Sidekiq 全体の `retry: 25` も生きているが、ジョブ単体の `retry_on` を「正」として扱う。理由は「ジョブのコードを読めば再実行戦略が分かる」状態にしたかったから。Sidekiq 全体の 25 回はあくまで catch-all のセーフティネットで、`retry_on attempts: 5` の方が先に効く。二重管理に見えるが、「ジョブ単位の意図」と「全体上限」は意味が違うので分けて管理する方が運用しやすいと判断。

### Outbox パターンを採らなかった

「after_commit と enqueue の間でプロセス落ち」を完全に閉じるには Outbox（DB に enqueue 予定を書き、別プロセスが Sidekiq に転記する）が要る。今回は採用していない:

- 問題スコープが「ActiveJob + Sidekiq の基本パターン」であり、Outbox 用の別テーブル/別プロセス導入は要件を超える
- 「after_commit 直後のプロセス落ち」は実害が低い（再 enqueue を運用で吸収可能なレベル）
- ジョブ側を冪等にしてあるので、仮に再投入されても副作用は二重発生しない

挙動として「at-least-once（多重実行は許す）」を選んだ上で、「冪等性ガードでアプリ整合性を保つ」という割り切り。

### `discard_on ActiveJob::DeserializationError` だけに絞った

`discard_on` の対象を `ActiveRecord::RecordNotFound` まで広げるかは迷ったが、

- 削除済 Comment は ActiveJob のシリアライズで先に `DeserializationError` になる（引数 ID 受け取り型でも、内部で `GlobalID` を使う引数型でも結果は同じ）。
- `RecordNotFound` を discard 対象にすると「単に DB が一瞬応答してないだけ」のケースまで永久に切り捨てられる。

ので、`RecordNotFound` は明示的に握り潰さず `retry_on StandardError` に流す方針。

### Comment#after_commit に置くか、Service 層に置くか

「副作用を model のコールバックに書くと密結合になる」批判は理解した上で、

- 通知の発火条件が「Comment が COMMIT されたこと」と一対一なので、第三者からこの規約を破られない場所（=モデル）に置くのが安全
- Service 層で `Comment.create!` を包む案も検討したが、controller 以外（rake / コンソール）から Comment が作られた時に通知漏れが起きる
- 第6問で `Posts::Publisher` を作った時とは違って、ここでの主目的は「DB コミットとジョブ投入の境界の明示」なので、その境界を持っている `after_commit` が一番素直

`after_commit` を直接書いた。ジョブ呼び出しが増えるなら `Comment.after_commit_callbacks` を別モジュールに切り出すリファクタは将来余地として残す。

### Sidekiq 設定の最小化

`dead_max_jobs` と `dead_timeout_in_seconds` だけ明示し、`concurrency` や `queues` は触らない。本問は「リトライと冪等性」が主題で、ワーカチューニングは別軸。Dead Set 設定だけは「メモリ無限増加を避ける」運用上の前提条件として明示しておく必要があった。

### スコープ外として明示

- Outbox パターン導入（at-most-once 等の上位保証）
- Dead Set からの Slack / Sentry 通知配線（インフラ層）
- スケジューラ / cron 系ジョブ（本問は after_commit 駆動のみ）
- ActiveJob 引数を `GlobalID` 化する変更（現状の `comment_id` 渡しで十分機能）

## 証跡

### 二重実行の再現（冪等性確認）

`bundle exec rails runner` で同一 `comment_id` に対し `perform_now` を 3 回連続実行し、`Rails.logger` 出力と DB 状態をキャプチャした実測:

```
===== captured Rails.logger output =====
[INFO] [CommentNotificationJob] notified post=206 comment=601
[INFO] [CommentNotificationJob] already notified, skipped (comment=601, ActiveRecord::RecordInvalid)
[INFO] [CommentNotificationJob] already notified, skipped (comment=601, ActiveRecord::RecordInvalid)
===== assertion =====
notifications_count: 0 -> 1 (delta=1)
CommentNotification rows for comment=601: 1
```

読み解き:

- 1 回目: `CommentNotification.create!` 成功 → `notifications_count` +1 → "notified" ログ
- 2 回目 / 3 回目: `create!` が uniqueness validation で `ActiveRecord::RecordInvalid` → rescue で短絡 → "already notified, skipped" ログ。トランザクション内の `update_all` は走らないので加算は発生しない
- 結果: 3 回実行しても `notifications_count` の delta は 1、`CommentNotification` 行も 1 件のまま

これが at-least-once 配送下でジョブが多重実行された時の実挙動。`ActiveRecord::RecordInvalid` で握り潰しているのは「DB 側 UNIQUE 制約 (`ActiveRecord::RecordNotUnique`) と、Rails のバリデーション層のどちらが先に弾いても同じ意味」なので両方 rescue 対象にしている。

### 仕様の宣言確認

`spec/jobs/comment_notification_job_spec.rb` で `retry_on StandardError` / `discard_on ActiveJob::DeserializationError` がジョブクラスに宣言されていることを `described_class.rescue_handlers` 経由で検証している（rescue_handlers 経由なので、宣言が消えると spec が即座に落ちる構造）。
