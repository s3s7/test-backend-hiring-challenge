require 'rails_helper'

RSpec.describe Tenant, type: :model do
  let(:valid_attrs) { { name: 'Acme', subdomain: "acme-#{SecureRandom.hex(4)}" } }

  it '有効な属性で valid' do
    expect(described_class.new(valid_attrs)).to be_valid
  end

  it 'name が空なら invalid' do
    expect(described_class.new(valid_attrs.merge(name: ''))).to be_invalid
  end

  it 'subdomain が空なら invalid' do
    expect(described_class.new(valid_attrs.merge(subdomain: ''))).to be_invalid
  end

  describe 'subdomain の format' do
    it '大文字を含むなら invalid' do
      expect(described_class.new(valid_attrs.merge(subdomain: 'Acme'))).to be_invalid
    end

    it '記号（@, 空白等）を含むなら invalid' do
      expect(described_class.new(valid_attrs.merge(subdomain: 'acme corp'))).to be_invalid
    end

    it '先頭/末尾がハイフンなら invalid' do
      expect(described_class.new(valid_attrs.merge(subdomain: '-acme'))).to be_invalid
      expect(described_class.new(valid_attrs.merge(subdomain: 'acme-'))).to be_invalid
    end

    it '内側のハイフンは valid' do
      expect(described_class.new(valid_attrs.merge(subdomain: 'acme-corp'))).to be_valid
    end
  end

  describe 'subdomain の一意性（大小無視）' do
    it '大小違いでも 2 件目は invalid' do
      sub = "uniq-#{SecureRandom.hex(4)}"
      described_class.create!(name: 'X', subdomain: sub)
      dup = described_class.new(name: 'Y', subdomain: sub.upcase)
      expect(dup).to be_invalid
    end
  end
end
