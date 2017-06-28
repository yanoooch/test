#
# HTTPヘッダ記録スクリプト
# written by Yano_Yuki10071197 2017.06.29
#
ini = <<"EOS"

; ===================================================================================
; 設定
; ===================================================================================
[system]
; log_write : ログ記録するかどうか（0:記録せず標準出力 / 1:記録する）
; timeout : レスポンスのないヘッダデータをメモリへ保持する秒数（設定秒数経過後に破棄）
log_write = 1
timeout = 300

[log]
;; HTTPヘッダを記録するログファイル
; log_dir     : ログファイルの出力先ディレクトリ（絶対パス）
; file_prefix : ログファイル名の先頭
; file_suffix : ログファイル名の末尾の表示形式
log_dir = /var/log/httpd/
file_prefix = http_header_log
file_suffix = %Y-%m-%d

[status]
;; ログに記録するヘッダのHTTPステータスコード
; get_status : ALLで全てのHTTPヘッダを記録する。
;              任意のステータスコードを入力すると、該当ステータスのみ記録する。
;              （カンマ区切りで複数のステータス入力可）
get_status = ALL

[command]
;; シェルのコマンド詳細設定
; tcpdump : tcpdumpコマンドとオプション（コマンドパスは絶対指定）
tcpdump = /sbin/tcpdump -i venet0:0 port 80 -Anns 2000 -l 2>&1
; ===================================================================================

EOS

require "open3"


# 設定読み込みクラス
# [name]
# hoge = val
# の値は、インスタンス名 ["name", "hoge"] の書式で参照できる
class LoadIni < Hash
  def initialize(ini)
    iniarr = ini.split("\n")
    sectionName = ""
    iniarr.each do |line|
      if line =~ /^#/
      elsif line =~ /\[(.*)\]/
        sectionName = $1.strip
      elsif line =~ /(.*?)=(.*)/
        self[ sectionName,  $1.strip] = $2.strip if sectionName != ""
      end
    end
  end #def initialize

  def []( section, *rest)
    return super(section) if rest.length == 0
    key=rest[0]
    self[section] ? self[section][key]  : nil
  end # def []( section, *rest)

  def []=( section, *rest )
    if rest.length == 1
      hash = rest[0]
      return super( section, hash)
    elsif rest.length == 2
      key, val = rest[0], rest[1]
      return (self[section] || super(section, Hash.new))[ key ]= val
    else
      raise "invalid number of param"
    end
  end #def []=( section, *rest )
end # class LoadIniFile



# ログ記録用クラス
class LogOutput
  # 標準出力を抑制してファイルへ出力スタート
  def self.start(log_dir, file_prefix, file_suffix)
    logname = log_dir + file_prefix + "." + Time.new.strftime(file_suffix)
    file = open(logname, 'a')
    # ファイル書き込みのバッファリングを無効化
    file.sync = true
    # 標準出力をファイル出力へ切り替え
    $stdout = file
  end

  # ファイルへの出力を停止して標準出力へ戻す
  def self.stop
    $stdout.close
    $stdout = STDOUT
  end
end # class LogOutput


# 標準出力のバッファリングを無効化
STDOUT.sync = true

# 設定読み込み
ini = LoadIni.new(ini)


# tcpdumpを実行して標準出力へ渡す
Open3.popen3(ini["command", "tcpdump"]) do |stdin, stdout, stderr, wait_thr|
  # 標準入力を閉じる
  stdin.close_write

  begin
    # ログ記録開始
    LogOutput.start(ini["log", "log_dir"], ini["log", "file_prefix"], ini["log", "file_suffix"])

    http_header = ""
    request = []
    response = []

    # 標準出力、標準エラーの出力があるまで延々と待ち、随時1行ずつ書き出す
    loop do IO.select([stdout, stderr]).flatten.compact.each do |io|
      io.each do |line|
        next if line.nil? || line.empty?
        http_header << line

        # リクエストヘッダ処理
        # 配列の中に {:seq 数値, :header "リクエストヘッダ全体文字列"} のハッシュを格納する
        while http_header =~ /\A.*?(\d\d:\d\d:\d\d\..*?\n).*?((?:GET|POST) .*?\r\n)\r\n/m
          hash = {seq: $1, header: $1 + $2, time: Time.now}
          # TCPヘッダ1行目のシーケンス番号をハッシュキーとして上書き
          hash[:seq] = $1.to_i if hash[:seq] =~ /seq \d+:(\d+)/
          # キャプチャ元から配列に入れた部分は削除して上書き
          http_header = $1 + $2 if http_header =~ /\A(.*?)\d\d:\d\d:\d\d\..*?\n.*?(?:GET|POST) .*?\r\n\r\n(.*)\z/m
          request.push(hash) unless hash.empty?
          hash = {}
        end

        # レスポンスヘッダ処理
        # 配列の中に {:ack 数値, :header "レスポンスヘッダ全体文字列"} のハッシュを格納する
        while http_header =~ /\A.*?(\d\d:\d\d:\d\d\..*?\n).*?(HTTP\/[12](?:\.[01])? (\d{3}) .*?\r\n)\r\n/m
          # ステータスコード status: も格納しておいて、絞り込みに利用できるようにしておく
          hash = {ack: $1, header: "\n" + $1 + $2, status: $3.to_i, time: Time.now}
          # TCPヘッダ1行目のackの数値をハッシュキーとして上書き
          hash[:ack] = $1.to_i if hash[:ack] =~ /ack (\d+)/
          # レスポンスは行頭に"> "付きで記録する
          hash[:header].gsub!(/^/, "> ")
          # キャプチャ元から配列に入れた部分は削除して上書き
          http_header = $1 + $2 if http_header =~ /\A(.*?)\d\d:\d\d:\d\d\..*?\n.*?HTTP\/[12](?:\.[01])? \d{3} .*?\r\n\r\n(.*)\z/m
          response.push(hash) unless hash.empty?
          hash = {}
        end

        # リクエストヘッダ配列、レスポンスヘッダ配列共にデータが入っている場合
        unless request.empty? && response.empty?
          i = 0
          while i < request.count
            tmp = []
            response.each { |v| tmp.push(v.values_at(:ack)).flatten! }
            # リクエストのシーケンス番号でレスポンスのackを検索して、最初にマッチした添字で紐付ける
            if response_index = tmp.index(request[i][:seq])
              # リクエストヘッダとレスポンスヘッダをペアで出力
              puts request[i][:header], response[response_index][:header], "\n"
              # 出力した場合は配列から削除
              request.delete_at(i)
              response.delete_at(response_index)
              next # 配列から削除した場合は i へ加算せずにループ継続
            end
            i += 1
          end
        end

        # 格納してから300秒以上経った要素は削除
        request.delete_if { |v| v[:time] < Time.now - 300 }
        response.delete_if { |v| v[:time] < Time.now - 300 }

        # ループ前にhttp_headerのゴミ掃除（最後のキャプチャブロックのみ残す）
        http_header = $1 if http_header =~ /\A.*\n(\d\d:\d\d:\d\d\.\d{6}.*?)\z/m

        end # io.each
      end # IO.select([stdout, stderr]).flatten.compact.each

      # 標準出力、標準エラーでEOFが検知された、つまり外部コマンドの実行が終了したらループを抜ける
      break if stdout.eof? && stderr.eof?
    end # loop

    puts "EOF検知でループ終了"

    # ログ記録終了
    LogOutput.stop

  # エラー処理
  rescue => e
    puts e.class
    puts e.message
    puts e.backtrace
  end
end
