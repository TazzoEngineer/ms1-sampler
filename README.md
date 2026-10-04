# MS-1 Sampler

Roland MS-1 風のスマホ用サンプラー（Flutter / Android・iOS）。

厳密なエミュレータではなく、「録って・切って・パッドで鳴らす」操作感を手軽に再現することを目指しています。
Roland 社とは無関係の個人プロジェクトです。

## できること

- **再生音の取り込み（Android 10 以降）**: 他のアプリで流している音を直接取り込む
  - 「再生音を聴き始める」で一度だけ許可すると、バックグラウンドで直近 60 秒を聴き続ける
  - 通知の「直前を取り込む」ボタン、またはアプリ内のボタンで直前 5〜60 秒を保存。アプリを切り替えずに取り込める
  - 開始〜停止で好きな長さを録音することもできる
  - 取り込んだ音は「取り込み一覧」に残る（左スワイプで削除）
  - 録音を拒否しているアプリ（多くのストリーミングサービス）の音は無音になる
- **マイク録音**: 音楽向けに自動ゲイン・ノイズ除去はオフ。録り終わったら最大音量に揃えて（ノーマライズ）トリミング画面へ
- **読み込み**: WAV ファイル（PCM 8/16/24/32bit・float32、ステレオはモノラルに変換）
- **トリミング**
  - 波形上の開始/終了ハンドルをドラッグ、2 本指ピンチで拡大縮小
  - ±1 / 10 / 100 ms の微調整
  - ハンドルを離すとゼロクロスに吸着、切り出しの両端に 3 ms のフェード（プチノイズ防止）
  - 「頭を音の立ち上がりへ」で開始位置を自動調整
  - 拍数を選ぶと長さから BPM を表示（ループの長さ合わせ用）
- **パッド**: 4×4 の 16 パッド
  - ワンショット / 押している間 / ループ（もう一度叩くと停止）
  - 指が触れた瞬間に発音。同じパッドは叩き直すと前の音を止める
  - 「編集」モードでモード変更・トリミングし直し・削除
- **テンポとループ**
  - 全体の BPM を 1 つ持つ（−/＋、数字をタップして入力、TAP を拍に合わせて叩く、トリム画面の推定値から設定）
  - ループのパッドは「周期」（16 分〜4 小節）と「オフセット」（周期の頭から 16 分音符単位）を持ち、全体のテンポに合わせて鳴る
  - 音が周期より短ければ残りは無音。長ければ、鳴り終わった後の最初の小節の頭から次を鳴らす（重ならない）
  - 何も鳴っていなければ押してすぐ、他のループが鳴っていれば次の小節の頭から鳴り始める。止めるのも次の小節の頭
  - トリム画面の「拍に吸着」で、切り出す長さを 16 分音符の倍数に揃える
- **保存**: パッドの割り当て（元の音・切り出し範囲・鳴らし方）と画面の設定はアプリ内に保存され、次に開いたときに戻る

## 今後の予定

1. ステップシーケンサー（1 つの周期の中で複数回鳴らすパターン）
2. タイムストレッチ（音の高さを変えずに、取り込んだループを全体の BPM に合わせる）
3. ビット数・サンプリングレートを落とす「MS-1 モード」

## 開発

```sh
flutter pub get
flutter test
flutter run
```

`lib/` の構成:

| パス | 内容 |
|---|---|
| `audio/sample.dart` | モノラル PCM（float）とトリミング・ゼロクロス・立ち上がり検出 |
| `audio/wav.dart` | WAV のエンコード / デコード |
| `audio/recorder.dart` | マイク録音（`record` の PCM ストリーム） |
| `audio/playback_capture.dart` | 再生音の取り込み（ネイティブ側は `android/.../CaptureService.kt`） |
| `audio/pad_engine.dart` | 16 パッドの発音（`flutter_soloud`）。ループはバッファストリームに先読みで流し込む |
| `audio/loop_sequencer.dart` | ループをテンポに合わせて並べ、PCM を作る（ネイティブに依存しない） |
| `audio/tempo.dart` | BPM・周期・オフセットの計算、タップテンポ |
| `audio/pad_store.dart` | パッドの割り当てと設定の保存（`pads.json` と元音源の WAV） |
| `ui/home_page.dart` | パッド画面 |
| `ui/trim_page.dart` | トリミング画面 |
| `ui/captures_page.dart` | 取り込み一覧 |
| `ui/tempo_bar.dart` | BPM と拍の表示 |
| `ui/loop_timing_editor.dart` | ループの周期・オフセットの設定 |

テスト（`test/`）は SoLoud を使わない `FakeEngine`（`test/support/fake_engine.dart`）で動かします。
トリミング画面のテストは実機と同じ画面サイズで描くので、レイアウトのはみ出しも検出します。

アプリ ID は Android が `io.github.tazzoengineer.ms1_sampler`、iOS が `io.github.tazzoengineer.ms1Sampler`
（iOS のバンドル ID には `_` を使えないため）。

## ビルドとバージョン

GitHub Actions が次の 2 つを実行します。

| workflow | 内容 |
|---|---|
| `android.yml` | テスト → 署名済み APK をビルド → Artifact と GitHub Release に添付 |
| `ios.yml` | 署名なしの iOS ビルドが通るかの確認のみ（配布はしない） |

- 実行契機: `master` への push、または Actions 画面からの手動実行（任意のブランチ）
- バージョン: `pubspec.yaml` の `version` を基準に `0.1.0-develop.N`（versionCode は `N`）
- `N` は workflow の実行番号。常に増えるので、どのビルドも前のビルドの上書き更新としてインストールできる
- ビルドごとに GitHub Release `develop-0.1.0.N`（同名のタグも作られる）を作り、APK を添付する。Artifact は 7 日で消える
- 最新版: https://github.com/TazzoEngineer/ms1-sampler/releases/latest

基準バージョンを上げるときは `pubspec.yaml` の `version: 0.1.0+1` の `0.1.0` を変更します（`+1` は使われません）。

### スマホへのインストール

1. スマホのブラウザで上の releases/latest を開く
2. Assets の `ms1_sampler-0.1.0-develop.N.apk` をタップしてダウンロードし、開く
3. 初回は「提供元不明のアプリ」の許可を求められるので、ブラウザに許可する。Play プロテクトの警告は「インストール」で続行

## 署名

リリース署名の鍵はリポジトリの外に置いています。

| 場所 | 内容 |
|---|---|
| `~/.android-keys/ms1_sampler/release.jks` | 鍵ストア（PKCS12, alias `ms1_sampler`） |
| `~/.android-keys/ms1_sampler/key.properties` | パスワード等。`android/key.properties` はここへのシンボリックリンク |

**鍵ストアを失うと、以後のビルドを既存のアプリに上書きインストールできなくなります。** パスワードマネージャ等にバックアップしてください。

`android/key.properties` がないときはデバッグ鍵で署名されます（`flutter run --release` 用）。

### GitHub Secrets

CI は次の Secrets から `key.properties` を生成します。未設定ならビルドを失敗させます。

| Secret | 値 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `release.jks` を base64 にしたもの |
| `ANDROID_KEYSTORE_PASSWORD` | `key.properties` の `storePassword` |
| `ANDROID_KEY_ALIAS` | `key.properties` の `keyAlias` |
| `ANDROID_KEY_PASSWORD` | `key.properties` の `keyPassword` |

登録（個人アカウントの gh トークンを使う）:

```sh
D=~/.android-keys/ms1_sampler; R=TazzoEngineer/ms1-sampler
export GH_TOKEN=$(gh auth token --user TazzoEngineer)
prop() { sed -n "s/^$1=//p" $D/key.properties | tr -d '\n'; }
base64 -i $D/release.jks | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64 -R $R
prop storePassword | gh secret set ANDROID_KEYSTORE_PASSWORD -R $R
prop keyAlias | gh secret set ANDROID_KEY_ALIAS -R $R
prop keyPassword | gh secret set ANDROID_KEY_PASSWORD -R $R
```

## ライセンス

MIT
