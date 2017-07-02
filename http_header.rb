#!/bin/ruby
#
# HTTPヘッダ記録スクリプト
#
# history
# 2017.07.03 Yano_Yuki10071197
#   first release
#

ini = <<"EOS"
; ==============================================================================
; 設定
; ==============================================================================
[system]
; log_write : ログ記録するかどうか（0:記録せず標準出力 / 1:記録する）
; timeout   : レスポンスのないヘッダデータをメモリへ保持する秒数（設定秒数経過後に単独で出力）
; lockfile  : 二重起動防止に使うロックファイル名とパス
log_write = 1
timeout = 300
lockfile = /tmp/http_header.rb.lock

[log]
;; HTTPヘッダを記録するログファイル
; log_dir     : ログファイルの出力先ディレクトリ（絶対パス）
; file_prefix : ログファイル名
; file_suffix : ログファイル名の末尾の日付フォーマット
log_dir = /var/log/httpd/
file_prefix = http_header_log
file_suffix = %Y-%m-%d

[http]
;; ログに記録するヘッダのHTTPステータスコード
; get_status : ALLで全てのHTTPヘッダを記録する。
;              任意のステータスコードを入力すると、該当コードのヘッダのみ記録す る。
;              （カンマ区切りで複数のステータスコード入力可。例: 200,400,404）
get_status = ALL

[command]
;; シェルのコマンド詳細設定
; tcpdump : tcpdumpコマンドとオプション（コマンドパスは絶対指定）
tcpdump = /sbin/tcpdump -i venet0:0 port 80 -A -nn -p -s 2000 -l 2>&1
; ==============================================================================
EOS

require "open3"



## クラス定義 ##

# 設定読み込みクラス
class LoadIni < Hash
  # 初期化時に設定文字列を引数で与える
  def initialize(ini)
    iniarr = ini.split("\n")
    section_name = ""
    iniarr.each do |line|
      case line
      when /^[#;]/
      when /^\[(.*)\]/
        section_name = $1.strip
      when /(.*?)=(.*)/
        self[section_name, $1.strip] = $2.strip unless section_name == ""
      end
    end
  end

  # [name]
  # hoge = val
  # の val を、インスタンス名["name", "hoge"] の書式で参照させる
  def [](section, *rest)
    return super(section) if rest.length == 0
    key = rest[0]
    self[section] ? self[section][key] : nil
  end

  def []=(section, *rest)
    case rest.length
    when 1
      hash = rest[0]
      return super(section, hash)
    when 2
      key, val = rest[0], rest[1]
      return (self[section] || super(section, Hash.new))[key] = val
    else
      STDERR.print("Error: invalid number of param\n")
    end
  end
end # class LoadIni



# ログ記録用クラス
class LogOutput
  # 標準出力をファイルへの出力へ切り替える
  def self.start(log_dir, file_prefix, file_suffix)
    log_dir.gsub!(/\/$/, "")
    logname = log_dir + "/" + file_prefix + "." + Time.new.strftime(file_suffix)
    file = File.open(logname, 'a')
    if ! file
      STDERR.print("Error: failed to open #{logname}\n")
      exit 1
    end
    file.sync = true
    $stdout = file
  end

  # ファイルへの出力を停止して標準出力へ戻す
  def self.stop
    $stdout.close
    $stdout = STDOUT
  end
end # class LogOutput



# 二重起動防止クラス
class LockFile
  # ロックファイルを排他ロックして二重起動を防止する
  def self.lock(lockfile)
    st = File.open(lockfile, 'a')
    if ! st
      STDERR.print("Error: failed to open #{lockfile}\n")
      exit 1
    end

    begin
      locked = st.flock(File::LOCK_EX|File::LOCK_NB)
      return st if locked
      STDERR.print("Error: process already running!\n")
      exit 1
    rescue
      STDERR.print("Error: failed to lock #{lockfile}\n")
      exit 1
    end

    return nil
  end

  # ロック解除
  def self.unlock(st)
    begin
      st.flock(File::LOCK_UN)
      st.close
    rescue
      STDERR.print("Error: failed to unlock lockfile")
      return false
    end

    return true
  end
end # class LockFile



## メイン処理 ##

# 標準出力のバッファリングを無効化
STDOUT.sync = true

# 実行ユーザチェック
unless ENV['USER'] == "root"
  STDERR.print("Error: This script must be run as the \"root\" user.\n")
  exit 1
end

# 設定読み込み
ini = LoadIni.new(ini)
timeout = ini["system", "timeout"]
lockfile = ini["system", "lockfile"]

# 二重起動防止
lock_st = LockFile.lock(lockfile)

# HTTPステータスコード設定チェック
get_status = ini["http", "get_status"].gsub(/,/, "|")
unless get_status =~ /^(?:ALL|\d{3}(?:\|\d{3})*)$/
  STDERR.print("Error: Format error of HTTP status code setting.\n")
  exit 1
end

# シグナルハンドラ
Signal.trap(:INT) do
  LockFile.unlock(lock_st)
  exit 1
end
Signal.trap(:TERM) do
  LockFile.unlock(lock_st)
  exit 1
end

# tcpdumpを実行して標準出力へ渡す
Open3.popen3(ini["command", "tcpdump"]) do |stdin, stdout, stderr, wait_thr|
  # 標準入力を閉じる
  stdin.close_write

  begin
    # ログ記録開始
    if ini["system", "log_write"] == "1"
      LogOutput.start(ini["log", "log_dir"], ini["log", "file_prefix"], ini["log", "file_suffix"])
      log_day = Time.now.day
    end

    capture_data = ""
    request = []
    response = []

    # 標準出力、標準エラーの出力があるまで延々と待ち、随時1行ずつ書き出す
    loop do
      IO.select([stdout, stderr]).flatten.compact.each do |io|
        io.each do |line|
          next if line.nil? || line.empty?
          capture_data << line

          # リクエストヘッダ処理
          while capture_data =~ /\A.*?(\d\d:\d\d:\d\d\..*?\n).*?((?:GET|POST) .*?\r\n)\r\n/m
            hash = {seq: $1, header: $1 + $2, time: Time.now}
            hash[:seq] = $1.to_i if hash[:seq] =~ /seq \d+:(\d+)/
            # キャプチャデータから配列に入れた部分は削除して上書き
            capture_data = $1 + $2 if capture_data =~ /\A(.*?)\d\d:\d\d:\d\d\..*?\n.*?(?:GET|POST) .*?\r\n\r\n(.*)\z/m
            request.push(hash) unless hash.empty?
            hash = {}
          end

          # レスポンスヘッダ処理
          while capture_data =~ /\A.*?(\d\d:\d\d:\d\d\..*?\n).*?(HTTP\/[12](?:\.[01])? (\d{3}) .*?\r\n)\r\n/m
            # ステータスコードも格納しておいて、絞り込みに利用できるようにしておく
            hash = {ack: $1, header: "\n" + $1 + $2, status: $3, time: Time.now}
            hash[:ack] = $1.to_i if hash[:ack] =~ /ack (\d+)/
            # レスポンスは行頭に "> " 付きで出力する
            hash[:header].gsub!(/^/, "> ")
            # キャプチャデータから配列に入れた部分は削除して上書き
            capture_data = $1 + $2 if capture_data =~ /\A(.*?)\d\d:\d\d:\d\d\..*?\n.*?HTTP\/[12](?:\.[01])? \d{3} .*?\r\n\r\n(.*)\z/m
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
                if get_status == "ALL"
                  puts request[i][:header], response[response_index][:header], "\n"
                elsif response[response_index][:status] =~ /#{get_status}/o
                  puts request[i][:header], response[response_index][:header], "\n"
                end
                # 出力した要素は配列から削除
                request.delete_at(i)
                response.delete_at(response_index)
                next # 削除した場合は i へ加算せずにループ継続
              end
              i += 1
            end
          end

          # 格納してから設定のタイムアウト値が経過した要素は、単独で出力してから削除
          request.delete_if do |v|
            if v[:time] < Time.now - timeout.to_i
              puts "timeout\n", v[:header], "\n"
              true
            else
              false
            end
          end
          response.delete_if do |v|
            if v[:time] < Time.now - timeout.to_i
              puts "timeout\n", v[:header], "\n"
              true
            else
              false
            end
          end

          # ループ前にキャプチャデータのゴミ掃除（最後のキャプチャブロックのみ残す）
          capture_data = $1 if capture_data =~ /\A.*\n(\d\d:\d\d:\d\d\.\d{6}.*?)\z/m

          # 日付が変わったらログファイルを変更する
          if ini["system", "log_write"] == "1"
            unless Time.now.day == log_day
              LogOutput.stop
              LogOutput.start(ini["log", "log_dir"], ini["log", "file_prefix"], ini["log", "file_suffix"])
              log_day = Time.now.day
            end
          end

        end # io.each
      end # IO.select([stdout, stderr]).flatten.compact.each

      # EOFが検知された、つまり外部コマンドの実行が終了したらループを抜ける
      break if stdout.eof? && stderr.eof?
    end # loop

    puts "Error: Since EOF was detected, the script is terminated."

    # ログ記録終了
    LogOutput.stop if ini["system", "log_write"] == "1"

    LockFile.unlock(lock_st)
    exit 1

  rescue => e
    LockFile.unlock(lock_st)
    puts e.class
    puts e.message
    puts e.backtrace
  end
end
