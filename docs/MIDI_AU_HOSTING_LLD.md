# MIDI / AU(AUv3) ホスティング LLD

HLD: [MIDI_AU_HOSTING_HLD.md](MIDI_AU_HOSTING_HLD.md)

- ステータス: Implemented (MVP) / Phase 2以降は継続課題
- 対象: macOS 11以上、現行の`X68000 macOS`ターゲット
- 実装言語: Swift + C/C++ bridge
- 方針: 既存のゲストエミュレーションを保ち、host側のMIDI/Audio実装だけを段階的に差し替える

## 1. Module構成

このLLDの分割案は将来の深いModule化を含む。MVPでは既存の`MIDIController`、`AudioStream`、`GameScene`、macOS設定UIへ責務を追加し、既存の呼び出し互換性を優先している。

### 1.1 実装先の候補

```text
X68000 Shared/
  Audio/
    AudioGraphController.swift
    AudioRenderCore.h/.c          // C ABI、リアルタイム側
    AudioRingBuffer.h/.c           // 固定長SPSC
    AudioClockMapper.swift
    AudioRecordingTap.swift
  MIDI/
    MIDIEvent.swift
    MIDIEventParser.swift
    MIDIEventRouter.swift
    CoreMIDIOutputAdapter.swift
    RS232CMIDIOutputAdapter.swift
    RawSerialMIDITransport.swift
    AUMIDIOutputAdapter.swift
    MIDIOutputConfiguration.swift
  MIDIController.swift             // 移行完了後は互換Facadeまたは削除
  AudioStream.swift                // 移行完了後はAudioGraphのFacadeへ変更
  px68k/x68k/midi.c/.h             // ゲストMIDI boardとhost bridge
  px68k/x68k/scc.c/.h              // SCC/serial transportのMIDI mode
  px68k/x11/dswin.c                // AudioRenderCore producerへの移行

X68000 macOS/
  MIDIAndAudioSettingsView.swift   // OUT-A/OUT-B/AU/gain設定
  AudioUnitSettingsWindowController.swift // SwiftUIをNSWindowへhost
```

Xcodeの`project.pbxproj`へ新規C/Swiftファイルを追加し、`AudioToolbox`、`AVFAudio`、`CoreMIDI`をmacOS targetへ明示的にリンクする。AU/AUv3本体はリポジトリへ同梱せず、`AVAudioUnitComponentManager`でシステム登録済みのものを実行時に検索する。

### 1.2 InterfaceとDepth

| Module | 公開Interface | Implementationに隠すもの | Depth / Leverage |
| --- | --- | --- | --- |
| `MIDIEventRouter` | `setOutputs`、`submit`、`panic`、状態取得 | CoreMIDI、RS-232C、AU、遅延、Fan-out、失敗処理 | 深い。GameSceneからApple/termios型を排除 |
| `CoreMIDIOutputAdapter` | `open`、`send`、`close` | port、endpoint、EventList構築、UniqueID再解決 | CoreMIDI固有処理を一箇所に局所化 |
| `RS232CMIDIOutputAdapter` | `open`、`send`、`panic`、`close` | fd、termios、31,250 baud、TX queue、SCC bridge | RS-232C固有処理を一箇所に局所化 |
| `AUMIDIOutputAdapter` | `open`、`send`、`close` | AU instance、sample time、MIDI block、availability | AU固有処理を一箇所に局所化 |
| `AudioUnitSettingsViewModel` | `reload`、`apply`、`openEditor`、状態取得 | UserDefaults、AU discovery、window lifecycle | UIからgraph/Adapter mutationを排除 |
| `GuestMIDIInputBridge` | （後続）`enqueue`、`service` | RX FIFO、status、IRQ、baud/tick | MIDI IN後続フェーズの予約Seam |
| `AudioGraphController` | `prepare`、`loadInstrument`、`start`、`stop` | AVAudioEngineのnode接続、再構成、AU lifecycle | UIからgraph mutationを隠す |
| `AudioRenderCore` | `produce`、`consume`、stats | OPM/ADPCM mix、resampler、PCM queue | render callbackを小さくする |

ここでInterfaceは単なる型名ではなくテスト面である。`MIDIEventRouter`にFake Adapterを挿せば、実機やAUなしで順序、Fan-out、panic、overflowを検証できる。CoreMIDIとRS-232Cの2つの物理Adapterを持つことで、二重出力のSeamを実際に検証できる。

## 2. データ型

### 2.1 MIDIイベント（C ABI）

Swiftの`[UInt8]`をCoreMIDI/AUのcallbackやqueueの共有データとして使わない。固定長slotをCで定義し、所有権と上限を固定する。

```c
#define X68_MIDI_EVENT_MAX_BYTES 4096
#define X68_MIDI_SAMPLE_TIME_IMMEDIATE INT64_MIN

typedef enum {
    X68_MIDI_SOURCE_GUEST = 0,
    X68_MIDI_SOURCE_CORE_MIDI = 1,
    X68_MIDI_SOURCE_AUDIO_UNIT = 2
} X68MIDIEventSource;

typedef struct {
    uint64_t sequence;
    uint64_t emulatorTick;       // X68000 emulation clock domain
    int64_t hostSampleTime;      // INT64_MIN means immediate
    uint8_t source;
    uint8_t cable;
    uint16_t length;
    uint8_t bytes[X68_MIDI_EVENT_MAX_BYTES];
} X68MIDIEvent;
```

要件:

- `length == 0`または`length > X68_MIDI_EVENT_MAX_BYTES`は拒否する。
- AUへ渡すイベントはrunning statusなしに展開する。
- SysExは単独イベントにする。AUの`scheduleMIDIEventBlock`仕様上、SysExと他イベントを同じchunkに混在させない。
- Realtime byteはSysEx中でも別イベントとして順序を維持する。
- 4096 byteを超えるSysExはPhase 1ではdropしてカウンタを増やす。将来は複数chunkとAU固有上限をAdapterのcapabilityにする。

### 2.2 出力構成と永続化

物理MIDI OUTは固定2スロットとして表現する。CoreMIDIとRS-232Cを一つの排他的enumへ押し込めず、両方を同時に有効化できる値型にする。AUは物理出力とは別の音源設定として保持する。

```swift
struct AUComponentKey: Equatable, Codable {
    let type: UInt32
    let subtype: UInt32
    let manufacturer: UInt32
    let version: UInt32?
    let name: String
}

struct RS232CMIDIOutputConfiguration: Equatable, Codable {
    var enabled: Bool = false
    var devicePath: String?
    // MIDI DIN/serial bridge baseline: 31,250 baud, 8-N-1.
    let baudRate: Int = 31_250
    let dataBits: Int = 8
    let stopBits: Int = 1
    let parity: Int = 0
}

struct MIDIOutputConfiguration: Equatable, Codable {
    var coreMIDIEnabled: Bool = false
    var coreMIDIUniqueID: Int32?
    var rs232c: RS232CMIDIOutputConfiguration = .init()
}

struct AudioUnitConfiguration: Equatable, Codable {
    var enabled: Bool = false
    var component: AUComponentKey?
    var gainDB: Float = 0
}

struct AudioGraphConfiguration: Codable {
    var emulatorSampleRate: Int = 22_050
    var emulatorGainDB: Float = 0
    var masterGainDB: Float = 0
    var midiOutputs: MIDIOutputConfiguration = .init()
    var audioUnit: AudioUnitConfiguration = .init()
}
```

`MIDIEndpointRef`、`AudioComponent`、`AVAudioUnit`のインスタンスは保存しない。起動時に`coreMIDIUniqueID`と`AudioComponentDescription`から再解決する。AU一覧が更新された場合は名前ではなく`type/subtype/manufacturer`を主キーとし、version/nameは表示・診断用に使う。既存の`midiOutputRoute`設定がある場合は、`.hardware`をOUT-Aへ、`.fanOut`をOUT-A + AUへ移行し、入力設定は読み捨てる。

AU gainは`-60 dB ... 0 dB`をUI範囲とし、初期値は0 dBとする。`AVAudioMixerNode.outputVolume`の0〜1.0制約に合わせ、設定値はAUプラグインのparameter/stateではなく、ホスト側の専用`auMixer` bus gainである。

### 2.3 Graph状態

```swift
enum AudioGraphState {
    case stopped
    case preparing
    case running
    case reconfiguring
    case failed(message: String)
}
```

`AudioGraphState`とAUの参照はserial `audioControlQueue`だけで変更する。`AVAudioSourceNode`のrender blockからstate、engine、AUのattach/detachを触らない。

## 3. MIDI実装詳細

### 3.1 ゲストからhostへの出力

現行`X68000_GetMIDIBuffer()`は、4096 byteの静的配列を返して直ちにsizeを0へ戻すだけで、timestampもqueueのatomic契約もない。これを次のC bridgeへ置き換える。

```c
typedef struct {
    uint8_t value;
    uint8_t reserved[3];
    uint64_t emulatorTick;
} X68MIDIByte;

uint32_t X68000_MIDI_DrainOutgoing(X68MIDIByte *dst, uint32_t capacity);
// Future MIDI IN only; do not add to the MVP bridge.
uint32_t X68000_MIDI_EnqueueIncoming(const X68MIDIByte *src, uint32_t count);
void X68000_MIDI_ServiceIncoming(uint64_t currentEmulatorTick);
```

実装規則:

1. `MIDI_Write()`のOut Data Byteで、ゲストTX FIFOの状態を更新した後、`X68MIDIByte`を固定長SPSC queueへ入れる。
2. `MIDI_Timer()`は既存のTX empty timingを維持し、hostへの送出を待つ責務と混同しない。
3. `GameScene`から直接C配列を借りず、`MIDIEventRouter`が事前確保した`X68MIDIByte`配列へdrainする。
4. `MIDIEventParser`がbyte列をイベントへまとめ、イベント先頭byteのtickをイベントtimestampの基準にする。
5. macOS targetでは`midi.c`のWinMM `midiOut*`を呼ばない。macOSの`fake.c`は`midiOutOpen`が失敗を返すため、host出力をC/Swiftの別経路へ分散させず、RouterからCoreMIDI OUT-A、RS-232C OUT-B、AUへ配信する。

移行期間は`X68000_GetMIDIBuffer`を互換APIとして残してもよいが、新実装からは呼ばない。overflow時はゲストCPUをblockせず、drop counterと最後にdropしたtickをMonitorへ出す。

### 3.2 MIDI parser

`MIDIEventParser`はAudio render threadではなく、エミュレーション制御threadまたはMIDI control queueだけで実行する。

状態:

```text
runningStatus: UInt8?
pendingStatus: UInt8?
pendingDataCount: Int
inSysEx: Bool
sysExBuffer: fixed/preallocated buffer
```

処理規則:

- `0xF8...0xFF`のRealtimeは、現在のSysEx/通常イベントを壊さず即時イベント化する。
- `0xF0`から`0xF7`までは1 SysExイベントとする。
- Channel Voiceのrunning statusは内部で完全なstatus byteへ展開する。
- F1/F2/F3/F6などSystem Commonのdata長を明示する。
- 不正status、SysEx overflow、未完了イベントはparser resetとdrop counterで復帰する。

### 3.3 Router Interface

```swift
protocol MIDIOutputAdapter: AnyObject {
    var isReady: Bool { get }
    func send(_ event: X68MIDIEvent) -> MIDIAdapterResult
    func panic()
    func close()
}

enum MIDIAdapterResult {
    case accepted
    case dropped(reason: String)
    case unavailable(reason: String)
}

final class MIDIEventRouter {
    func setOutputs(_ outputs: MIDIOutputConfiguration) async throws
    func setAudioUnit(_ audioUnit: AUMIDIOutputAdapter?)
    func submit(_ event: X68MIDIEvent)
    func drainGuestOutput(currentHostSampleTime: AVAudioFramePosition)
    func panic()
}
```

`setOutputs`はOUT-A、OUT-Bのopen/closeを一つのcontrol queueで直列化する。AUのload/unloadは`AudioGraphController`が同じcontrol queueのライフサイクルで行い、準備完了後に`setAudioUnit`でRouterへ登録する。`submit`は有効な全Adapterへ同じsequenceのイベントを渡すが、RS-232Cのwrite完了までCoreMIDIやゲストを待たせない。Adapterは「送信完了」ではなく、送信可能なqueueへ受け付けた時点で`accepted`を返してよい。

実際のSwift実装では、CoreMIDI/AU/termiosの型がInterfaceへ漏れないよう、`X68MIDIEvent`をSwiftでbridge可能な値型としてラップする。`GameScene`が呼ぶのは`drainGuestOutput`と設定変更だけにする。MIDI INの`handleHostInput`は今回のInterfaceへ含めず、後続フェーズで別のInput Adapterとして追加する。

### 3.4 CoreMIDI output Adapter

`CoreMIDIOutputAdapter`のopen手順:

1. `MIDIClientCreateWithBlock`でclientを1つ作る。
2. `MIDIOutputPortCreate`でoutput portを作る。
3. 保存された`MIDIUniqueID`から`MIDIObjectFindByUniqueID`でendpointを再解決する。
4. endpointがDestinationであること、名称を取得できることを確認する。
5. MIDI 1.0 bytesをMIDI 1.0 UMP wordsへ変換し、`MIDIEventListInit(kMIDIProtocol_1_0)` / `MIDIEventListAdd`でイベントを組み立てる。`MIDIEventList`へraw bytesをそのまま入れない。
6. `MIDISendEventList`で送り、OSStatusを記録する。UMP encoderで扱えないSysExはcompatibility用`MIDIPacketList`またはdropへ回す。

現在の`GetDest()`のように全Destinationへ送らない。device setup notificationはCoreMIDI callbackから直接配列を変更せず、control queueへ再列挙要求をpostする。`MIDIUniqueID`が消えた場合はOUT-AだけをOffへ戻し、OUT-BとAUは継続する。

MIDI 1.0 baselineでは`MIDISendEventList`を使う。古い`MIDIPacketList`はcompatibility fallbackに限定する。送信timestampは0固定にせず、`AudioClockMapper`が算出した`MIDITimeStamp`を使う。EventListを使うためのbyte↔UMP encoder/decoderは`CoreMIDIEncoding`という小さなModuleへ閉じ込める。

### 3.5 RS-232C MIDI OUT Adapter

```swift
final class RS232CMIDIOutputAdapter: MIDIOutputAdapter {
    private let transport: RawSerialMIDITransport

    var isReady: Bool { transport.isReady }

    func send(_ event: X68MIDIEvent) -> MIDIAdapterResult {
        guard event.length > 0 else { return .dropped(reason: "empty MIDI event") }
        return transport.enqueue(event.bytes, sequence: event.sequence)
    }

    func panic() {
        transport.enqueuePanicForAllChannels()
    }

    func close() {
        transport.close()
    }
}
```

`RawSerialMIDITransport`の責務は次のとおり。

- 選択された`/dev/cu.*`などのデバイスを専用fdでopenする。
- raw MIDI 1.0の31,250 baud、8 data bits、no parity、1 stop bitを実際のデバイスへ設定する。Swiftの表示用`baudRate`だけを変更して成功扱いにしない。
- `X68MIDIEvent`をイベント境界のまま固定長TX queueへコピーし、serial I/O threadがbyte列を順番にwriteする。
- queue full、short write、`EIO`、切断をカウンタと状態へ反映する。write失敗でRouterの他Adapterを止めない。
- MIDI event間の順序を保つ。timestampを持たないserialへwall-clock遅延を二重適用しない。

実装方式は、既存のゲストSCC Port Bへ直接`SCC_Write()`させるのではなく、host側の専用serial transportを第一候補とする。これにより、ゲストの通常シリアル文字とMIDI eventが一つのbyte streamへ混ざらない。既存SCCのfdを共用する場合は、次のC ABIを追加し、`SCC_MODE_SERIAL_MIDI`を排他的なPort B modeとして扱う。

```c
int SCC_SetMode(int mode, const char *config); // SCC_MODE_SERIAL_MIDI + device path
int SCC_SendMIDIBytes(const BYTE *data, uint32_t length);
int SCC_ConfigureMIDI(void);                   // 31,250 / 8-N-1
```

`SCC_SendMIDIBytes`は既存の1 byte `write()`を呼び出し元で繰り返さず、固定TX queueへコピーする。`SCC_ReceiveThread`は今回のMIDI INを実装しないため`serialMIDI` modeでは起動しない。`SCC_OpenFile`の現行B9600固定、headerと実装のmode定義差、未実装の`SCC_ConfigureSerial`は同じ変更で整理する。

RS-232Cの電圧レベルはDIN MIDIの電流ループではないため、`devicePath`は直接DIN端子を意味しない。UIには「RS-232C↔MIDI変換器が必要」と表示し、変換器なしの直結をサポート対象にしない。

### 3.6 MIDI IN（後続フェーズ、今回の実装対象外）

MIDI INは今のRouter/設定画面へ含めない。後続で追加する場合のSeamだけを次の形で予約する。

```swift
protocol MIDIInputAdapter: AnyObject {
    func start() throws
    func stop()
    // callback threadから固定input queueへcopyするだけ
}
```

将来の`CoreMIDIInputAdapter`は`MIDIInputPortCreateWithProtocol`でSourceを明示接続し、callbackでは固定長queueへのcopyとoverflow counterだけを行う。`GuestMIDIInputBridge`はそのqueueをエミュレーションthreadで消費し、CZ-6BM1のRX FIFO/status/IRQ仕様が確定してから実装する。

今回のリリースでは`selectedInputUniqueID`、`midiThruToAudioUnit`、CoreMIDI input port、RS-232C input readerを持たない。

```text
future CoreMIDI/RS-232C receive thread
    -> host input SPSC queue
    -> EmulationHost tick service
    -> X68000_MIDI_EnqueueIncoming
    -> CZ-6BM1 RX FIFO/status/IRQ
    -> MIDI_Read()でX68000 softwareが読む
```

`midi.c`には受信FIFO、受信データready/status、FIFO overrun、受信割り込みを追加する。R04/R05相当の正確なbit配置は、CZ-6BM1の実機仕様と既存X68000ソフトで決め、テストに固定する。現行`MIDI_Read()`の空caseを推測で埋めない。

受信timestampが現在のemulator tickより先なら、byteをそのtickまでRX FIFOへ投入しない。厳密なbaud互換が必要なソフトには`MIDIBUFTIMER`相当の10 MHz tick間隔を適用する。初期実装は1 byte/受信timestampでよく、ゲストIRQの発生順を優先する。

## 4. AU host実装詳細

### 4.1 検索とinstantiate

```swift
let description = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice,
    componentSubType: 0,
    componentManufacturer: 0,
    componentFlags: 0,
    componentFlagsMask: 0
)

let candidates = AVAudioUnitComponentManager
    .shared()
    .components(matching: description)
    .filter { $0.hasMIDIInput && $0.isSandboxSafe }
```

Swift nameはSDK importに合わせて確認するが、実装責務は次のとおり。

- `kAudioUnitType_MusicDevice`を基線にする。
- `hasMIDIInput`、`passesAUVal`、`availableArchitectures`、`sandboxSafe`を表示・判定する。
- `AVAudioUnit.instantiate(with:options:completionHandler:)`は`audioControlQueue`から呼ぶ。
- instantiate完了までmain threadをblockしない。
- AUv2の同期initializerに依存しない。AUv3または非同期生成は`instantiate`を使う。
- `AVAudioUnitMIDIInstrument`として返った場合も、汎用byte送出にはwrapped `auAudioUnit`を使う。

### 4.2 AU Adapter

```swift
final class AUMIDIOutputAdapter: MIDIOutputAdapter {
    private let audioUnit: AVAudioUnit
    private let schedule: AUScheduleMIDIEventBlock
    private let clockMapper: AudioClockMapper

    func send(_ event: X68MIDIEvent) -> MIDIAdapterResult {
        let sampleTime = clockMapper.auSampleTime(for: event)
        event.bytes.withUnsafeBufferPointer { bytes in
            schedule(sampleTime, event.cable,
                     bytes.count, bytes.baseAddress!)
        }
        return .accepted
    }
}
```

実装上の注意:

- `audioUnit.auAudioUnit.scheduleMIDIEventBlock`を`allocateRenderResourcesAndReturnError`前に取得してcacheする。
- Blockがnil、`isMusicDeviceOrEffect == false`、`hasMIDIInput == false`ならAdapterを作らない。
- `scheduleMIDIEventBlock`はMIDI 1.0イベント用。macOS 12以上では`AUMIDIEventListBlock`を優先する実装を別Adapterとして追加する。
- `cable`は初期値0。AUの`virtualMIDICableCount`を超える値はdropする。
- `AUScheduleMIDIEventBlock`のbytes pointerはcall中だけ有効な固定バッファとし、Blockの外へ保持しない。
- AUがSysExを受け付けない場合はcomponent capabilityまたはsend errorをUIへ反映する。
- Note/CCだけに限定せず、Program Change、Pitch Bend、Channel Pressure、System Common、SysExを同じイベントモデルで扱う。

`AVAudioUnitMIDIInstrument.sendMIDIEvent`等は簡単なUI previewには使えるが、通常のゲスト出力では使わない。そうしないとSysExとtimestampの処理が別経路になり、Route間の挙動が一致しない。

### 4.3 AU Audio Node接続

```swift
engine.attach(emulatorSourceNode)
engine.attach(emulatorMixer)
engine.attach(auInstrument)
engine.attach(auMixer)

engine.connect(emulatorSourceNode, to: emulatorMixer, format: hostFormat)
engine.connect(emulatorMixer, to: engine.mainMixerNode, format: hostFormat)
engine.connect(auInstrument, to: auMixer, format: hostFormat)
engine.connect(auMixer, to: engine.mainMixerNode, format: hostFormat)
```

`AudioGraphController`が次を直列化する。

```text
stopped
  -> preparing: output format取得、source/ring準備
  -> preparing: AU instantiate、attach/connect
  -> preparing: AU render resources、MIDI Adapter公開
  -> running: engine.prepare/start
```

AUを交換するときは、control queueで以下を行う。

1. Routerを一時停止し、新規MIDIイベントをpending queueへ置く。
2. 旧AUへ全channelのAll Notes Off、All Sound Off、Reset All Controllersを送る。
3. engineをpauseまたはstopし、旧AUとのconnectionを切る。
4. 新AUをattach/connectし、formatを確認する。
5. render resourcesを確保し、engineを再開する。
6. 新AUへ送るべきpendingイベントだけを再生する。

Graphを動かしたままのattach/detachに依存しない。AVAudioEngineは動作中の変更を一部サポートするが、AUのrender resourceとMIDI event queueの整合性を優先して停止点を作る。

### 4.4 AU UIと音量設定

既存の`Preferences…`/Settingsメニューの設定領域に、`CRTSettingsWindowController` / `NSHostingView`パターンで`AudioUnitSettingsWindowController`と`MIDIAndAudioSettingsView`を追加する。トップレベルのシリアル操作メニューとは分け、UIはAUの内部DSPを直接操作せず、`AudioUnitSettingsViewModel`を介して`AudioGraphController`と`MIDIEventRouter`へ設定を渡す。

```text
MIDI & Audio Unit Settings
  MIDI OUT-A (CoreMIDI)
    [Use] [Destination picker] [status]
  MIDI OUT-B (RS-232C)
    [Use] [Device picker] [31,250 baud / 8-N-1] [status]
    [RS-232C↔MIDI converter required]
  Audio Unit
    [Use Audio Unit] [Instrument picker] [Refresh] [status]
    AU volume: [-60 dB ... 0 dB] [value] [Reset]
    [Open Plug-in UI] / unavailable reason
```

必須動作:

- `Use Audio Unit`がOffのときはAUをinstantiateせず、FM+ADPCMと有効なMIDI OUTだけを動かす。
- Onにしたときは選択した`AUComponentKey`を非同期instantiateし、成功後だけ`auMixer`へ接続する。ロード中はUI操作をdisableし、失敗理由を表示する。
- AU volume sliderは`auMixer.outputVolume`相当のホストbus gainへ反映し、`AudioUnitConfiguration.gainDB`として保存する。FM/ADPCM、OUT-A、OUT-Bのレベルには影響させない。
- sliderは0.5 dB刻みとし、`-60 dB`を実質mute、`0 dB`を上限とする。設定変更はcontrol queueで適用するが、gain更新のためにengine全体をstopしない。
- AUがcustom editor viewを提供するときだけ別windowの`NSViewController`へhostする。対応viewがないAUは`Open Plug-in UI`操作時にエラーを表示し、音量・AU選択は継続して使用できる。
- AU pickerは表示名だけを保存せず、component descriptionを主キーにする。消えたAUは自動instantiateせず「未接続」と表示する。
- OUT-A/OUT-Bの失敗はAU UIの状態を壊さず、各出力のstatusへ個別表示する。MVPのOUT-BはSCCとは別の専用host transportを開くため、ゲストの通常SCC設定とは共有しない。

`AudioUnitSettingsViewModel`は`@MainActor`のUI stateだけを持ち、engine・AU instance・CoreMIDI endpoint・serial fdを所有しない。pickerの更新はdiscovery serviceへ、applyはcontrol queueへ委譲する。`NSWindowController`は一つのsettings windowを保持し、再度メニューを選んだ場合は既存windowを前面へ出す。

永続化キーは次を基線とする。

```text
MIDIOutput.CoreMIDI.Enabled
MIDIOutput.CoreMIDI.UniqueID
MIDIOutput.RS232C.Enabled
MIDIOutput.RS232C.DevicePath
AudioUnit.Enabled
AudioUnit.ComponentDescription
AudioUnit.GainDB
```

`31,250 baud`、8-N-1はMIDI modeの固定仕様なので、通常シリアル用の9600/19,200などをこの設定画面で選ばせない。設定の保存は成功した構成だけを行い、open/instantiateに失敗した値を次回起動の有効状態として保存しない。

### 4.5 AU MIDI output（後続）

AUのMIDI outputが必要になった場合は、`MIDIOutputEventListBlock`を設定し、callbackから固定queueへコピーしてCoreMIDIまたはゲストRXへRouteする。callbackから直接`MIDISend`は行わない。初期スコープではAU MIDI outputを無効にする。

## 5. AudioRenderCore詳細

### 5.1 既存処理との対応

現行`dswin.c`は次の順序で動く。

```text
emulator hsync
  -> DSound_Send0(clock)
  -> sound_send(frames)
  -> ADPCM_Update(adpcmBuf)
  -> OPM_Update(opmBuf)
  -> int16 add + clip
  -> pcmbuffer ring
```

移行後もFM/ADPCMの生成タイミングはエミュレーションthreadに残す。

```text
emulator hsync
  -> AudioRenderCore.produce(nativeFrames)
  -> ADPCM_Update / OPM_GenerateNative (ymfm YM2151)
  -> int32 mix + int16 clip
  -> native PCM SPSC ring

Direct HAL AudioUnit or AudioQueue render
  -> AudioRenderCore.consumeInt16/consumeFloat32(hostFrames)
  -> fixed-point linear resampler (62.5 kHz -> host rate)
  -> host stereo output
```

Audio callback側で不足分を`DSound_Send()`してエミュレータ状態を変更する処理は廃止する。
X68000のYM2151は4 MHzで動作するため、ymfmの`2 x 32`分周からnative rateは
62,500 Hzになる。AudioUnit/AudioQueueのバッファ設定はnative生成とは分離し、
macOSではDirect HAL AudioUnitを既定の64 frames、16/32/128/256/512 framesも
選択可能とする。

### 5.2 C interface

```c
void X68000_AudioRenderReset(void);
void X68000_AudioRenderSetHostRate(uint32_t hostRate);
uint32_t X68000_AudioRenderNativeSampleRate(void);
void X68000_AudioRenderProduce(uint32_t nativeFrames);
void X68000_AudioRenderConsumeFloat32(float *left,
                                      float *right,
                                      uint32_t hostFrames);
void X68000_AudioRenderConsumeInterleavedFloat32(float *buffer,
                                                 uint32_t hostFrames);
void X68000_AudioRenderConsumeInt16(int16_t *buffer,
                                    uint32_t hostFrames);
void X68000_AudioRenderCaptureEnable(int enabled);
void X68000_AudioRenderCapture(const int16_t *buffer,
                               uint32_t frames);
uint32_t X68000_AudioRenderCaptureRead(int16_t *buffer,
                                       uint32_t maximumFrames);
```

`X68000_AudioRenderProduce()`は`DSound_Send0()`から呼ぶ。OPM/ADPCMの既存stateを他threadから触らない。
`Consume*()`はAudioUnit/AudioQueueのrender callbackからのみ呼び、callback側でSwift
closureやエミュレータstateへ触れない。録音が有効な場合もcallbackは固定長のC ringへ
コピーするだけで、AVAssetWriterへの投入は別のcontrol queueで行う。

### 5.3 Mixとlevel

初期値は互換性を優先する。

1. ADPCM/OPMをそれぞれ既存の`OPM_VOL`/`PCM_VOL`で生成する。
2. 既存同様にint32で加算する。
3. `[-32768, 32767]`へclipしてnative busを作る。
4. `Float32`へ正規化し、`emulatorGainDB`を適用する。
5. main mixerでAU busと加算し、`masterGainDB`を適用する。

AUとの合成でclipする場合は、まずbus gainを下げる。Phase 2ではsoft limiterを自動挿入せず、波形互換性と音量を測定してから選択する。これによりFM+ADPCMだけの出力が意図せず変わらない。

### 5.4 SPSC ring

```text
producer: emulation thread
  writeIndex (atomic release)
  [fixed stereo native PCM slots]

consumer: audio render thread
  readIndex (atomic acquire)
  [fixed stereo native PCM slots]
```

規則:

- capacityはpower-of-two、最低100 ms native framesから開始する。
- producerはfull時にblockしない。新しいframeをdropしてoverrunを増やす。
- consumerはempty時にzero-fillしてunderrunを増やす。
- indexは`uint32_t` wrapを許容し、producer/consumer以外から直接変更しない。
- ringのformat、sample rate、resampler stateをgraph再構成時にresetする。
- mutex、`malloc`、Swift closure、`Data`、`debugLog`をrender blockへ持ち込まない。

`volatile`だけではSPSCのmemory orderingを保証できない。C11 atomic、または既存プロジェクトで利用可能なC++ atomicを使用する。

### 5.5 Host render callback

Direct HAL AudioUnitおよび互換AudioQueueのrender callbackは次だけを行う。

1. `AudioBufferList`のchannel layoutを検査する。
2. `X68000_AudioRenderConsumeInt16()`（またはFloat32版）を呼ぶ。
3. frameCount未満しか得られなければ残りをzero-fillする。
4. OSStatusを返す。

buffer pointerがnil、channel数が想定外、frameCountが上限超過の場合もzero-fillしてカウンタを増やす。ログや再構成はcontrol queueへ通知する。
録音tapはcallbackから直接呼ばず、固定長capture ringを経由してcontrol queueから消費する。

## 6. ClockMapper

### 6.1 Epoch

`AudioClockMapper`はAudioEngine開始時に一度epochを作る。

```swift
struct AudioEpoch {
    let emulatorTick: UInt64
    let hostSampleTime: AVAudioFramePosition
    let emulatorClockRate: Double
    let hostSampleRate: Double
}
```

変換:

```text
deltaTick = event.emulatorTick - epoch.emulatorTick
sample = epoch.hostSampleTime
       + round(Double(deltaTick) * hostSampleRate / emulatorClockRate)
```

`emulatorClockRate`は`clockMHz`の表示値を直接仮定せず、C coreが使うtick定義（現行の10 MHz threshold）に合わせる。clock modeやresetでtick domainが変わる場合はepochを再作成し、pending eventをImmediateへ降格する。

### 6.2 遅延・late event

```text
if eventSample < currentAudioSample:
    AUEventSampleTimeImmediate
else if eventSample - currentAudioSample < lookAheadLimit:
    eventSample
else:
    clamp to currentAudioSample + lookAheadLimit
```

`lookAheadLimit`は初期4096 frames以下にする。AU側のschedule blockへ300 msを直接与えず、必要なHardware補正だけを`hostSampleTime`へ加算する。遅延適用箇所はRouterに一つだけ置く。

CoreMIDIへのtimestampも同じepochからhost clockへ変換する。MIDI hardwareの送信はdevice/driver latencyがあるため、AUと完全同時になるとは仮定せず、実機測定値を設定へ保存できるようにする。

## 7. AudioGraphController詳細

### 7.1 prepare

```swift
final class AudioGraphController {
    private let controlQueue = DispatchQueue(label: "MPX68K.AudioGraph")
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var emulatorMixer: AVAudioMixerNode?
    private var auInstrument: AVAudioUnit?
    private var auMixer: AVAudioMixerNode?
    private var auAdapter: AUMIDIOutputAdapter?

    func prepare(configuration: AudioGraphConfiguration) async throws
    func loadInstrument(_ id: AUComponentKey) async throws
    func setAudioUnitGainDB(_ value: Float)
    func unloadInstrument() async
    func start() throws
    func stop()
}
```

prepareの順序:

1. output nodeからhost sample rate/channel数を取得する。
2. `X68000_AudioRenderReset`と`X68000_AudioRenderSetHostRate`へnative/host
   sample rateを渡し、ringとresamplerを初期化する。
3. Float32 non-interleavedのsource formatを作る。
4. source nodeとemulator mixerをattach/connectする。
5. main mixerを取得してsource busを接続する。
6. AUが有効かつ選択済みならinstantiate、attach、AUを専用`auMixer`へ接続し、そのbus gainを`configuration.audioUnit.gainDB`へ設定する。
7. AU render resources確保後、MIDI AdapterをRouterへ登録する。
8. `engine.prepare()`し、`startAndReturnError`で開始する。

### 7.2 device変更

`AVAudioEngineConfigurationChangeNotification`受信時は、通知handlerから直接engineを作り直さない。

```text
notification
  -> controlQueueへ再構成要求
  -> Router pause / pending保持
  -> engine stop
  -> output format再取得
  -> source/ring/resampler reset
  -> graph reconnect
  -> engine start
  -> pendingのlate eventをImmediateで再送
```

再構成に失敗した場合はAUだけを外し、FM+ADPCMのsourceを再生できる最小graphへfallbackする。

### 7.3 録画tap

`AudioStream.recordingTap`のstatic closureをrender処理の一部として残さない。`mainMixerNode.installTap`でpost-mix Float32を受け、事前確保したpoolまたはbounded queueへコピーする。

ScreenRecorder側はそのqueueを別threadで読み、既存のAAC入力形式へ変換する。録画tapが遅い場合にaudio renderをblockせず、queueが満杯なら古い録音chunkをdropしてMonitorへ出す。録画開始・停止時だけtapをinstall/removeする。

## 8. エラーとpanic

### 8.1 MIDI

| エラー | 動作 |
| --- | --- |
| CoreMIDI Destination消失 | OUT-AだけをOff、OUT-B/AU/FM+ADPCMは継続 |
| RS-232C device open/baud設定失敗 | OUT-BだけをOff、OUT-A/AU/FM+ADPCMは継続 |
| RS-232C TX queue overflow / short write | 該当イベントをdropし、OUT-Bのcounter/statusを更新。他Adapterは継続 |
| 通常SCC Port Bとの競合 | MVPでは専用host transportのためゲストSCC接続とは競合しない |
| AU instantiate失敗 | AUだけをOff、OUT-A/OUT-B/FM+ADPCM継続 |
| schedule block nil | AUを非対応として表示 |
| MIDI queue overflow | drop、counter、最後のsource/tickを記録 |
| malformed SysEx | そのイベントだけdrop、parser reset |
| 出力構成変更 | 旧Adapterへpanic、各queueを安全に停止してから新構成へ切替 |

panicは全16 channelへ次を送る。

```text
Control Change 123: All Notes Off
Control Change 120: All Sound Off
Control Change 121: Reset All Controllers
```

既存の機種固有Reset SysExは、AUへ無条件に送らない。CoreMIDI/RS-232Cの物理出力では必要に応じて従来の`MIDI_Type` resetを使い、AUでは標準panicを使う。

### 8.2 Audio

- underrun: zero-fill、counter increment、連続回数を表示。
- overrun: producerをblockせずdrop、counter increment。
- AU render error: AU busをsilenceにし、graphを停止・再構成する。
- output format error: sourceをzeroにし、FM+ADPCM fallbackを試す。
- engine start error: `AudioGraphState.failed`にし、既存の音声停止UIへ通知する。

## 9. テスト計画

### 9.1 C core / host bridge

- `X68000_MIDI_DrainOutgoing`の順序、capacity、overflow。
- `SCC_MODE_SERIAL_MIDI`のopen/close、31,250 baud / 8-N-1設定、raw byte送信。
- RS-232C TX queueの順序、capacity、short write、切断、overflow。
- tickが単調増加すること、reset時のepoch更新。
- FM only、ADPCM only、FM+ADPCMの既存golden PCM比較。

RX FIFO、R04/R05相当register、status bit、IRQ発生順のテストはMIDI INを実装する後続フェーズへ移す。

### 9.2 MIDI Router

- running status、1-byte/2-byte/3-byte、System Common。
- SysEx中のRealtime、SysEx終了、overflow。
- Off、OUT-A、OUT-B、OUT-A + OUT-B、各出力 + AUの送信先と順序。
- CoreMIDI Adapter、RS-232C Adapter、AU AdapterをFakeにしたsequence/timestamp検証。
- CoreMIDI失敗、RS-232C失敗、AU失敗が互いのAdapterを停止させないこと。
- panic、出力構成切替、Destination消失、serial device切断。

### 9.3 Apple integration

- `AVAudioUnitComponentManager`からMusic Deviceを列挙できる。
- `sandboxSafe == false`を選択候補から除外できる。
- macOS 11で`AVAudioUnit.instantiate`と`scheduleMIDIEventBlock`が動く。
- `AVAudioEngine`のoffline/manual renderingで、AU Note On後に非ゼロ音声が出る。
- AU audio + FM + ADPCMの3信号がmain mixer後に同時に存在する。
- `auMixer`のgain変更がAU音声だけへ反映され、FM/ADPCMのレベルを変えない。
- `Use Audio Unit` Off時にAUをinstantiateせず、On時に非同期loadできる。
- custom editorの有無に応じてsettings windowを開くか、操作時にfallbackできる。
- AVAudioEngine configuration change、AU load/unload、app inactive/active。

### 9.4 実機確認

- CoreMIDI loopbackで送信byteとtimestampを記録。
- RS-232C/PTY loopbackでraw byte列、event順序、31,250 baud設定を確認。
- CoreMIDI OUT-AとRS-232C OUT-Bの同時送信、片方の切断時の継続を確認。
- 実機音源へのNote/CC/Program/SysEx送信。
- AU音源のcustom editor、AU音量、FM+ADPCMとのmix、latency、reset挙動。
- 30分連続再生時のunderrun/overrun、MIDI drop、CPU負荷。

## 10. 変更順序とコミット分割

1. `MIDIEvent`、parser、Fake Adapter、Routerを追加し、既存CoreMIDI送信をRouter経由へ移す。
2. CoreMIDI OUT-AをUniqueID/EventList送信へ置換する。
3. RS-232C OUT-Bの専用transport、MIDI mode、固定TX queue、raw byte loopbackを追加する。
4. OUT-A/OUT-Bの独立fan-out、panic、failure isolationを追加する。
5. AudioRingBufferとAudioRenderCoreを追加し、FM+ADPCMのgolden比較を通す。
6. AudioQueueをAVAudioEngine source graphへ切り替える。録画tapをpost-mixへ移す。
7. AU検索、非同期instantiate、AU Adapter、MIDI schedule、専用AU mixer gainを追加する。
8. `MIDI & Audio Unit Settings` UI、設定永続化、AU editor window、device/AU failure recoveryを追加する。
9. MIDI IN（CoreMIDI/RS-232C input、guest RX FIFO）は仕様確定後の別フェーズとする。
10. optionalなMIDIEventList/MIDI 2.0、Music Effect、AU MIDI outputを別コミットで追加する。

各段階で`X68000 macOS` Debug/Releaseをbuildし、`tests/core`と手動起動確認を行う。ROMやプラグイン本体はcommitしない。

## 11. 実装前に確定する判断

- CZ-6BM1 RX register/status/IRQの互換仕様。
- 22,050 Hz native audioからdevice rateへのresampler品質とCPU予算。
- AUの初期component選定と、custom editor viewがないAUのfallback表示。
- RS-232C↔MIDI変換器、デバイスパス、macOSで31,250 baudを設定する方式（termiosまたは`IOSSIOSPEED`）。
- MIDI OUT-Bを専用host serial transportで持つか、SCC Port Bの`serialMIDI`排他modeで持つか。推奨は専用transport。
- AU音量の初期値0 dB、UI範囲`-60 ... 0 dB`、clip/peak表示の扱い。
- MIDI INのRX register/status/IRQ仕様と、MIDI Thruの提供時期。
