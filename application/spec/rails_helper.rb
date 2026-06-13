require 'spec_helper'
# docker-compose で RAILS_ENV=development が固定されているため、||= だと
# rspec が dev 環境（dev DB）で走ってしまう。常に test を強制する。
ENV['RAILS_ENV'] = 'test'
require File.expand_path('../config/environment', __dir__)

abort("Rails環境が本番モードで実行されています！") if Rails.env.production?
require 'rspec/rails'

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.fixture_paths = [ "#{::Rails.root}/spec/fixtures" ]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  # 第8問: マルチテナント分離（共有スキーマ + tenant_id）の試験用デフォルト。
  # 既存 spec は Current.tenant を明示せず User/Post/Comment を作成しているため、
  # 各 example の前にデフォルトテナントを確立しておく。
  # クロステナント分離を検証する spec は Current.tenant を上書きすればよい。
  config.before(:each) do
    Current.reset
    Current.tenant = Tenant.find_by(subdomain: "default") ||
                     Tenant.create!(name: "Default", subdomain: "default")
  end
end
