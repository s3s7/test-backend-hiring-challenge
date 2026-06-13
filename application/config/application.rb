require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

module BackendApp
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[assets tasks])
    config.generators.system_tests = nil

    # 第7問: ActiveJob のバックエンドを Sidekiq に固定。
    # test 環境では config/environments/test.rb 側で :test adapter に上書きされる。
    config.active_job.queue_adapter = :sidekiq
  end
end
