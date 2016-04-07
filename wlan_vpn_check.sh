#!/bin/bash

source /home/oracle/.bash_profile

readonly MAIL_FROM="root@`hostname -s`.com"
readonly MAIL_TO="test@test.com"
readonly MAIL_SUBJECT="無線LAN設定の相違チェック `date +%Y%m%d`"

# 無線LAN設定テーブルのリストを取得
db1=`sqlplus -S / as sysdba <<EOF
set feedback off
set pages 0
select vpn_id||','||corporate_cd||','||client_ip||','||login_source_ip||','||agency_id||','||connection_limited||','||mac_address_max_count||','||force_mac_address_auth||','||wlan_user_login from db1.settei_t order by vpn_id;
exit
EOF`

# メール本文への検出レコード出力用の配列を定義
diff_corp=()

# 無線LAN設定の相違チェックのループ開始
while read vpn_id; do
  # 同じvpn_idのレコードを抽出
  grep_vpn_id=`echo "$db1" | grep "^$vpn_id"`

  # 無線LAN設定のユニーク数を取得
  uniq_wlan=`echo "$grep_vpn_id" | awk -F, '{print $3","$4","$5","$6","$7","$8","$9}' | sort -u | wc -l`

  # 無線LAN設定のユニーク数が1つなら次のループへ、1つでなければ該当レコードを配列へ格納
  if [ "$uniq_wlan" = 1 ]; then
    continue
  else
    diff_corp=(${diff_corp[@]} $grep_vpn_id)
  fi
done < <(echo "$db1" | awk -F, '{print $1}' | uniq) # vpn_idのユニークリストでループ

# メールヘッダ定義
mailhead="From: $MAIL_FROM
To: $MAIL_TO
Subject: =?ISO-2022-JP?B?`echo $MAIL_SUBJECT | nkf -MB`?=
MIME-Version: 1.0
Content-Type: text/plain; charset=ISO-2022-JP
Content-Transfer-Encoding: base64

"

# メール本文定義
mailbody="settei_tの無線LAN設定の相違を検出しました。
以下の検出レコードを確認して対応してください。

【表示項目】
vpn_id,corporate_cd,client_ip,login_source_ip,agency_id,connection_limited,mac_address_max_count,force_mac_address_auth,wlan_user_login

【検出レコード】
`for i in ${diff_corp[@]}; do
  echo $i
done`

"

# 無線LAN設定の相違が存在した場合はメール送信
if [ -n "${diff_corp[*]}" ]; then
  mailbody=`echo -n "$mailbody" | nkf -MB` #文字コードをJISに変換してからbase64エンコード
  echo "$mailhead$mailbody" | /usr/lib/sendmail -f $MAIL_FROM -i -t
  echo "無線LAN設定の相違を検出、詳細をメール送信完了"
else
  echo "該当レコード無し"
fi

