# frozen_string_literal: true

namespace :app do
  desc "壊れたデータ（NULL必須項目・重複email・重複subdomain等）を冪等に修復する"
  task fix_data: :environment do
    # lib/ は autoload 対象外のため明示 require。詳細は notes/3-validation.md。
    require Rails.root.join("lib/data_fixer.rb").to_s
    DataFixer.run!
  end
end
