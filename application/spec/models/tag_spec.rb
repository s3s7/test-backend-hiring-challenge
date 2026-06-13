require 'rails_helper'

RSpec.describe Tag, type: :model do
  it 'name の presence を検証する' do
    tag = described_class.new(name: '')
    expect(tag).to be_invalid
  end

  it '同名（大小無視）は一意' do
    described_class.create!(name: 'Ruby')
    dup = described_class.new(name: 'ruby')
    expect(dup).to be_invalid
  end

  it 'posts を has_many through で参照できる' do
    association = described_class.reflect_on_association(:posts)
    expect(association.macro).to eq(:has_many)
    expect(association.options[:through]).to eq(:post_tags)
  end
end
