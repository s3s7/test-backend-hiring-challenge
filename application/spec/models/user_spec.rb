require 'rails_helper'

RSpec.describe User, type: :model do
  let(:valid_attrs) do
    {
      name: 'Test',
      email: "user-#{SecureRandom.hex(8)}@example.com",
      password: 'password'
    }
  end

  it '名前なしでは無効' do
    user = described_class.new(email: 'test@example.com')
    expect(user).to be_invalid
  end

  it 'メールなしでは無効' do
    user = described_class.new(name: 'Test')
    expect(user).to be_invalid
  end

  it '多くの投稿を持つ' do
    association = described_class.reflect_on_association(:posts)
    expect(association.macro).to eq(:has_many)
  end

  describe 'バリデーション' do
    it '有効な属性で valid' do
      expect(described_class.new(valid_attrs)).to be_valid
    end

    it 'email の形式が不正なら invalid' do
      user = described_class.new(valid_attrs.merge(email: 'not-an-email'))
      expect(user).to be_invalid
      expect(user.errors[:email]).to be_present
    end

    it 'password が空なら invalid（暗号化を通さず生の空のまま保存し、presence で弾く）' do
      user = described_class.new(valid_attrs.merge(password: ''))
      expect(user).to be_invalid
      expect(user.errors[:password]).to be_present
    end

    it 'password が nil なら invalid' do
      user = described_class.new(valid_attrs.merge(password: nil))
      expect(user).to be_invalid
      expect(user.errors[:password]).to be_present
    end
  end

  describe 'email の正規化と一意性ポリシー（大小無視）' do
    it 'before_validation で email を小文字化・trim する' do
      user = described_class.new(valid_attrs.merge(email: '  ADMIN@Example.COM  '))
      user.valid?
      expect(user.email).to eq('admin@example.com')
    end

    it '大文字小文字違いでも同一 email として扱い、2件目は invalid' do
      existing_email = "dup-#{SecureRandom.hex(8)}@example.com"
      described_class.create!(valid_attrs.merge(email: existing_email))

      dup = described_class.new(valid_attrs.merge(email: existing_email.upcase))
      expect(dup).to be_invalid
      expect(dup.errors[:email]).to include(/taken/i).or include(I18n.t('errors.messages.taken'))
    end
  end

  describe '#authenticate' do
    it '正しいパスワードで true、誤りで false' do
      user = described_class.create!(valid_attrs.merge(password: 'secret123'))
      expect(user.authenticate('secret123')).to be true
      expect(user.authenticate('wrong')).to be false
    end
  end
end
