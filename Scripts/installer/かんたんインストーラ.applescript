-- PhotoViewer かんたんインストーラ
-- DMG の中のこのスクリプトをダブルクリックしてスクリプトエディタで開き、▶︎（実行）ボタンを押してください。
-- 次の 3 つを自動で行います。
--   1. PhotoViewer を「アプリケーション」フォルダへコピー
--   2. Gatekeeper の制限を解除（ダウンロードしたファイルに付く隔離属性 com.apple.quarantine を削除）
--   3. PhotoViewer を初めて起動

set appName to "PhotoViewer.app"
set appID to "com.geologycat.PhotoViewer"
set destPath to "/Applications/" & appName

-- このスクリプトと同じ場所（DMG の中）にあるアプリを探す
set srcPath to ""
try
	set myPath to POSIX path of (path to me)
	if myPath ends with ".scpt" then
		set myFolder to do shell script "dirname " & quoted form of myPath
		set candidate to myFolder & "/" & appName
		if (do shell script "test -d " & quoted form of candidate & " && echo yes || echo no") is "yes" then
			set srcPath to candidate
		end if
	end if
end try
-- 見つからなければ、マウント中の DMG から探す
if srcPath is "" then
	set srcPath to do shell script "ls -d /Volumes/PhotoViewer*/" & appName & " 2>/dev/null | head -n 1"
end if
if srcPath is "" then
	display dialog "インストールする PhotoViewer.app が見つかりませんでした。" & return & return & "DMG を開いたまま、DMG の中にある「かんたんインストーラ」を実行してください。" buttons {"OK"} default button "OK" with icon stop with title "PhotoViewer かんたんインストーラ"
	return
end if

-- 確認
set message to "PhotoViewer を「アプリケーション」フォルダにインストールします。" & return & return & "・アプリケーションフォルダへコピー" & return & "・Gatekeeper の制限を解除" & return & "・PhotoViewer を起動"
set alreadyInstalled to (do shell script "test -d " & quoted form of destPath & " && echo yes || echo no") is "yes"
if alreadyInstalled then
	set message to message & return & return & "すでにインストールされている PhotoViewer は新しいものに置き換えます（レーティングや設定は消えません）。"
end if
display dialog message buttons {"キャンセル", "インストール"} default button "インストール" cancel button "キャンセル" with title "PhotoViewer かんたんインストーラ"

-- 起動中なら終了する
if application id appID is running then
	try
		tell application id appID to quit
	end try
	delay 1
end if

-- 1. アプリケーションフォルダへコピー（書き込めなければ管理者のパスワードを求める）
set copyCommand to "rm -rf " & quoted form of destPath & " && ditto " & quoted form of srcPath & " " & quoted form of destPath
try
	do shell script copyCommand
on error
	try
		do shell script copyCommand with administrator privileges
	on error errMsg
		display dialog "コピーできませんでした。" & return & return & errMsg buttons {"OK"} default button "OK" with icon stop with title "PhotoViewer かんたんインストーラ"
		return
	end try
end try

-- 2. Gatekeeper の制限を解除（隔離属性を削除）
set unquarantine to "xattr -dr com.apple.quarantine " & quoted form of destPath
try
	do shell script unquarantine
on error
	try
		do shell script unquarantine with administrator privileges
	end try
end try

-- 3. 初回起動
do shell script "open " & quoted form of destPath

display dialog "インストールが完了しました。" & return & return & "PhotoViewer は「アプリケーション」フォルダにあります。DMG は取り出してかまいません。" buttons {"OK"} default button "OK" with title "PhotoViewer かんたんインストーラ" giving up after 30
