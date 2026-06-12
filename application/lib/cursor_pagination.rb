# frozen_string_literal: true

# キーセット（カーソル）ページネーションの共通実装。
#
# 並び順は `key DESC, id_key DESC`（新しい順 + 同値タイブレーク id 降順）固定。
# OFFSET 方式と違い、ページング途中で行が挿入/削除されても、すでに渡したカーソルより
# 「古い側」のページは安定して一意に返せる（行ズレなし）。詳細は notes/4-pagination.md。
#
# カーソルは (key の値, id) のタプルを JSON 化して URL-safe Base64 でエンコード。
# クライアントには不透明な文字列として扱わせる（中身の構造を契約に入れない）。
#
# MySQL の罠: タプル比較 `(a, b) < (?, ?)` はオプティマイザがレンジスキャンに
# 展開してくれず、(a, b) に複合インデックスを張ってもフルスキャンに落ちる。
# このため WHERE 句は OR の展開形で書き、(key, id_key) の複合インデックスと
# 組み合わせて type: range にする。EXPLAIN 結果は notes/4-pagination.md。
module CursorPagination
  DEFAULT_PER_PAGE = 20
  MAX_PER_PAGE = 100

  class InvalidCursor < StandardError; end
  class InvalidPerPage < StandardError; end

  module_function

  def parse_per_page(value, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
    return default if value.nil? || value.to_s.strip.empty?
    n = Integer(value.to_s, 10)
    raise InvalidPerPage, "per_page must be >= 1" if n < 1
    raise InvalidPerPage, "per_page must be <= #{max}" if n > max
    n
  rescue ArgumentError, TypeError
    raise InvalidPerPage, "per_page must be an integer"
  end

  # 次カーソルを最後尾レコードから組み立てる。タイムスタンプはマイクロ秒精度の
  # ISO8601 UTC（Z 接尾辞）で固定し、デコード側の TZ 解釈ブレを排除する。
  # カラム精度が秒（DATETIME(0)）でも、カーソルは DB から取得した値そのものを
  # encode するので精度ズレによる取りこぼしは起きない。
  def encode_cursor(record, key: :created_at, id_key: :id)
    payload = {
      c: record.public_send(key).utc.iso8601(6),
      i: record.public_send(id_key)
    }
    Base64.urlsafe_encode64(JSON.dump(payload), padding: false)
  end

  def decode_cursor(cursor)
    return nil if cursor.nil? || cursor.to_s.empty?
    raw = Base64.urlsafe_decode64(cursor.to_s)
    payload = JSON.parse(raw)
    [ Time.iso8601(payload.fetch("c")), Integer(payload.fetch("i")) ]
  rescue ArgumentError, JSON::ParserError, KeyError, TypeError
    raise InvalidCursor, "cursor is malformed"
  end

  # 1 ページを取得。`per_page + 1` 件取って has_next を判定し、余剰の 1 件を捨てる。
  def paginate(scope, cursor: nil, per_page: nil, key: :created_at, id_key: :id)
    per_page = parse_per_page(per_page)
    klass = scope.klass
    table = klass.quoted_table_name
    key_col = klass.connection.quote_column_name(key.to_s)
    id_col = klass.connection.quote_column_name(id_key.to_s)

    ordered = scope
      .reorder(Arel.sql("#{table}.#{key_col} DESC, #{table}.#{id_col} DESC"))

    if cursor && !cursor.to_s.empty?
      cursor_time, cursor_id = decode_cursor(cursor)
      # MySQL でインデックスを効かせるため、行値比較ではなく OR の展開形で書く。
      # (key, id) の複合インデックスがあれば type: range に解決される。
      ordered = ordered.where(
        "#{table}.#{key_col} < :t OR (#{table}.#{key_col} = :t AND #{table}.#{id_col} < :i)",
        t: cursor_time, i: cursor_id
      )
    end

    rows = ordered.limit(per_page + 1).to_a
    has_next = rows.size > per_page
    rows = rows.first(per_page)
    next_cursor = has_next && rows.last ? encode_cursor(rows.last, key: key, id_key: id_key) : nil

    {
      records: rows,
      meta: {
        per_page: per_page,
        has_next: has_next,
        next_cursor: next_cursor
      }
    }
  end
end
