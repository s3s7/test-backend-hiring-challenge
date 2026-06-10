# frozen_string_literal: true

Apartment.configure do |config|
  config.excluded_models = %w[
    Tenant
    User
    Post
    Comment
  ]

  config.tenant_names = []

  config.use_schemas = true
end
