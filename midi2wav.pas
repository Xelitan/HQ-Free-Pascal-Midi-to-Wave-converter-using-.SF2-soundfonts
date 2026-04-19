program Midi2Wav;

//MIDI to WAV Converter with SF2 SoundFont support
//License: MIT
//Author: www.xelitan.com
//Usage: midi2wav input.mid soundfont.sf2 output.wav

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const
  SAMPLE_RATE  = 44100;
  NUM_CHANNELS = 2;
  BIT_DEPTH    = 16;
  MAX_VOICES   = 256;
  MAX_MIDI_CH  = 16;

  // SF2 Generator operators
  GEN_START_ADDRS_OFFSET        =  0;
  GEN_END_ADDRS_OFFSET          =  1;
  GEN_STARTLOOP_ADDRS_OFFSET    =  2;
  GEN_ENDLOOP_ADDRS_OFFSET      =  3;
  GEN_START_ADDRS_COARSE_OFFSET =  4;
  GEN_MOD_LFO_TO_PITCH          =  5;
  GEN_VIB_LFO_TO_PITCH          =  6;
  GEN_MOD_ENV_TO_PITCH          =  7;
  GEN_INITIAL_FILTER_FC         =  8;
  GEN_INITIAL_FILTER_Q          =  9;
  GEN_MOD_LFO_TO_FILTER_FC      = 10;
  GEN_MOD_ENV_TO_FILTER_FC      = 11;
  GEN_END_ADDRS_COARSE_OFFSET   = 12;
  GEN_MOD_LFO_TO_VOLUME         = 13;
  GEN_PAN                       = 17;
  GEN_MOD_LFO_DELAY             = 21;
  GEN_MOD_LFO_FREQ              = 22;
  GEN_VIB_LFO_DELAY             = 23;
  GEN_VIB_LFO_FREQ              = 24;
  GEN_MOD_ENV_DELAY             = 25;
  GEN_MOD_ENV_ATTACK            = 26;
  GEN_MOD_ENV_HOLD              = 27;
  GEN_MOD_ENV_DECAY             = 28;
  GEN_MOD_ENV_SUSTAIN           = 29;
  GEN_MOD_ENV_RELEASE           = 30;
  GEN_KEY_TO_VOL_ENV_HOLD       = 39;
  GEN_KEY_TO_VOL_ENV_DECAY      = 40;
  GEN_VOL_ENV_DELAY             = 33;
  GEN_VOL_ENV_ATTACK            = 34;
  GEN_VOL_ENV_HOLD              = 35;
  GEN_VOL_ENV_DECAY             = 36;
  GEN_VOL_ENV_SUSTAIN           = 37;
  GEN_VOL_ENV_RELEASE           = 38;
  GEN_INSTRUMENT                = 41;
  GEN_KEY_RANGE                 = 43;
  GEN_VEL_RANGE                 = 44;
  GEN_STARTLOOP_ADDRS_COARSE    = 45;
  GEN_ENDLOOP_ADDRS_COARSE      = 50;
  GEN_INITIAL_ATTENUATION       = 48;
  GEN_COARSE_TUNE               = 51;
  GEN_FINE_TUNE                 = 52;
  GEN_SAMPLE_ID                 = 53;
  GEN_SAMPLE_MODES              = 54;
  GEN_SCALE_TUNING              = 56;
  GEN_EXCLUSIVE_CLASS           = 57;
  GEN_ROOT_KEY_OVERRIDE         = 58;

type
  TInt16  = SmallInt;
  TUInt16 = Word;
  TInt32  = LongInt;
  TUInt32 = LongWord;

// ===========================================================================
//  SF2 STRUCTURES
// ===========================================================================

type
  TSF2GenAmount = packed record
    case Byte of
      0: (Lo, Hi       : Byte);
      1: (ShortAmount  : TInt16);
      2: (UShortAmount : TUInt16);
  end;

  TSF2Gen = packed record
    Oper   : TUInt16;
    Amount : TSF2GenAmount;
  end;

  TSF2Bag = packed record
    GenIdx : TUInt16;
    ModIdx : TUInt16;
  end;

  TSF2Phdr = packed record
    PresetName : array[0..19] of Char;
    Preset     : TUInt16;
    Bank       : TUInt16;
    BagIdx     : TUInt16;
    Library_   : TUInt32;
    Genre      : TUInt32;
    Morphology : TUInt32;
  end;

  TSF2Inst = packed record
    InstName : array[0..19] of Char;
    BagIdx   : TUInt16;
  end;

  TSF2Shdr = packed record
    SampleName    : array[0..19] of Char;
    Start         : TUInt32;
    End_          : TUInt32;
    LoopStart     : TUInt32;
    LoopEnd       : TUInt32;
    SampleRate    : TUInt32;
    OriginalPitch : Byte;
    PitchCorrect  : ShortInt;
    SampleLink    : TUInt16;
    SampleType    : TUInt16;
  end;

  // Zone stores timecents (not seconds) so preset+instrument offsets can be
  // summed before final conversion.
  TZone = record
    SampleStart  : TUInt32;
    SampleEnd    : TUInt32;
    LoopStart    : TUInt32;
    LoopEnd      : TUInt32;
    SampleRate   : TUInt32;
    RootKey      : Integer;
    PitchCorr    : Integer;
    LoopMode     : Integer;

    // Volume envelope (timecents / centibels)
    VolEnvDelayTC  : Integer;
    VolEnvAttackTC : Integer;
    VolEnvHoldTC   : Integer;
    VolEnvDecayTC  : Integer;
    VolEnvSustainCB: Integer;   // centibels of attenuation; 0=full, 1000=silent
    VolEnvReleaseTC: Integer;
    KeyToVolHoldTC : Integer;   // timecents per key from key 60
    KeyToVolDecayTC: Integer;

    // Modulation envelope (timecents / centibels)
    ModEnvDelayTC  : Integer;
    ModEnvAttackTC : Integer;
    ModEnvHoldTC   : Integer;
    ModEnvDecayTC  : Integer;
    ModEnvSustainCB: Integer;
    ModEnvReleaseTC: Integer;
    ModEnvToPitchC : Integer;   // cents of pitch at mod env peak
    ModEnvToFilterC: Integer;   // cents of filter offset at mod env peak

    // Mod LFO
    ModLFODelayTC  : Integer;
    ModLFOFreqHz8  : Integer;   // frequency as centHz: freq = 8.176 * 2^(n/1200)
    ModLFOToPitch  : Integer;   // cents
    ModLFOToFilter : Integer;   // cents
    ModLFOToVol    : Integer;   // centibels

    // Vib LFO
    VibLFODelayTC  : Integer;
    VibLFOFreqHz8  : Integer;
    VibLFOToPitch  : Integer;   // cents

    AttenuationCB  : Integer;   // centibels (additive)
    Pan            : Double;
    ScaleTuning    : Integer;
    FineTune       : Integer;
    CoarseTune     : Integer;
    FilterCents    : Integer;   // absolute cents: 8.176 * 2^(n/1200)
    FilterQDB      : Double;    // dB

    StartOffset     : Int64;
    EndOffset       : Int64;
    LoopStartOffset : Int64;
    LoopEndOffset   : Int64;
    ExclusiveClass  : Integer;  // gen 57: 0 = none, >0 = mute group
    Valid           : Boolean;
  end;

  TZoneArray = array of TZone;

type
  TSF2 = class
  private
    FSamples   : array of TInt16;
    FSmpCount  : TUInt32;
    FPhdr      : array of TSF2Phdr;
    FPbag      : array of TSF2Bag;
    FPgen      : array of TSF2Gen;
    FInst      : array of TSF2Inst;
    FIbag      : array of TSF2Bag;
    FIgen      : array of TSF2Gen;
    FShdr      : array of TSF2Shdr;
    FPhdrN, FPbagN, FPgenN : Integer;
    FInstN, FIbagN, FIgenN : Integer;
    FShdN                  : Integer;

    procedure ApplyPgenToZone(BagIdx: Integer; var Z: TZone);
    procedure ApplyIgenSetToZone(BagIdx: Integer; var Z: TZone);
  public
    constructor Create(const FileName: string);
    destructor  Destroy; override;
    function    FindZones(Bank, Prog, Key, Vel: Integer; out Zones: TZoneArray): Integer;
    function    GetSample(P: TUInt32): TInt16; inline;
    property    SampleCount: TUInt32 read FSmpCount;
  end;

// ===========================================================================
//  Helper functions
// ===========================================================================

// Timecents to seconds: t = 2^(TC/1200)
function TC2Sec(TC: Integer): Double;
begin
  if TC <= -12000 then Result := 0.001
  else if TC >= 8000 then Result := 100.0
  else Result := Power(2.0, TC / 1200.0);
end;

// Centibels of attenuation to linear amplitude
function CB2Lin(CB: Integer): Double;
begin
  if CB <= 0 then Result := 1.0
  else if CB >= 1440 then Result := 0.0
  else Result := Power(10.0, -CB / 200.0);
end;

// LFO frequency in Hz from centHz-style encoding: 8.176 * 2^(n/1200)
function LFOFreq(TC: Integer): Double;
var e: Double;
begin
  e := TC / 1200.0;
  if e < -15 then e := -15;
  if e > 5 then e := 5;
  Result := 8.176 * Power(2.0, e);
end;

// ===========================================================================
//  TSF2 IMPLEMENTATION
// ===========================================================================

procedure TSF2.ApplyPgenToZone(BagIdx: Integer; var Z: TZone);
var g, GS, GE: Integer; Op: TUInt16; A: TSF2GenAmount;
begin
  GS := FPbag[BagIdx].GenIdx;
  if BagIdx + 1 < FPbagN then GE := FPbag[BagIdx + 1].GenIdx else GE := FPgenN;
  for g := GS to GE - 1 do
  begin
    Op := FPgen[g].Oper; A := FPgen[g].Amount;
    case Op of
      GEN_VOL_ENV_DELAY:   Z.VolEnvDelayTC   := Z.VolEnvDelayTC   + A.ShortAmount;
      GEN_VOL_ENV_ATTACK:  Z.VolEnvAttackTC  := Z.VolEnvAttackTC  + A.ShortAmount;
      GEN_VOL_ENV_HOLD:    Z.VolEnvHoldTC    := Z.VolEnvHoldTC    + A.ShortAmount;
      GEN_VOL_ENV_DECAY:   Z.VolEnvDecayTC   := Z.VolEnvDecayTC   + A.ShortAmount;
      GEN_VOL_ENV_SUSTAIN: Z.VolEnvSustainCB := Z.VolEnvSustainCB + A.UShortAmount;
      GEN_VOL_ENV_RELEASE: Z.VolEnvReleaseTC := Z.VolEnvReleaseTC + A.ShortAmount;
      GEN_KEY_TO_VOL_ENV_HOLD:  Z.KeyToVolHoldTC  := Z.KeyToVolHoldTC  + A.ShortAmount;
      GEN_KEY_TO_VOL_ENV_DECAY: Z.KeyToVolDecayTC := Z.KeyToVolDecayTC + A.ShortAmount;

      GEN_MOD_ENV_DELAY:   Z.ModEnvDelayTC   := Z.ModEnvDelayTC   + A.ShortAmount;
      GEN_MOD_ENV_ATTACK:  Z.ModEnvAttackTC  := Z.ModEnvAttackTC  + A.ShortAmount;
      GEN_MOD_ENV_HOLD:    Z.ModEnvHoldTC    := Z.ModEnvHoldTC    + A.ShortAmount;
      GEN_MOD_ENV_DECAY:   Z.ModEnvDecayTC   := Z.ModEnvDecayTC   + A.ShortAmount;
      GEN_MOD_ENV_SUSTAIN: Z.ModEnvSustainCB := Z.ModEnvSustainCB + A.UShortAmount;
      GEN_MOD_ENV_RELEASE: Z.ModEnvReleaseTC := Z.ModEnvReleaseTC + A.ShortAmount;
      GEN_MOD_ENV_TO_PITCH:     Z.ModEnvToPitchC  := Z.ModEnvToPitchC  + A.ShortAmount;
      GEN_MOD_ENV_TO_FILTER_FC: Z.ModEnvToFilterC := Z.ModEnvToFilterC + A.ShortAmount;

      GEN_MOD_LFO_DELAY:        Z.ModLFODelayTC   := Z.ModLFODelayTC  + A.ShortAmount;
      GEN_MOD_LFO_FREQ:         Z.ModLFOFreqHz8   := Z.ModLFOFreqHz8  + A.ShortAmount;
      // Note: gen 5 is also GEN_MOD_LFO_TO_PITCH but only at instrument level
      GEN_MOD_LFO_TO_FILTER_FC: Z.ModLFOToFilter  := Z.ModLFOToFilter + A.ShortAmount;
      GEN_MOD_LFO_TO_VOLUME:    Z.ModLFOToVol     := Z.ModLFOToVol    + A.ShortAmount;

      GEN_VIB_LFO_DELAY:        Z.VibLFODelayTC   := Z.VibLFODelayTC  + A.ShortAmount;
      GEN_VIB_LFO_FREQ:         Z.VibLFOFreqHz8   := Z.VibLFOFreqHz8  + A.ShortAmount;
      GEN_VIB_LFO_TO_PITCH:     Z.VibLFOToPitch   := Z.VibLFOToPitch  + A.ShortAmount;

      GEN_INITIAL_ATTENUATION:  Z.AttenuationCB   := Z.AttenuationCB  + A.UShortAmount;
      GEN_PAN:          Z.Pan         := Z.Pan + (A.ShortAmount / 500.0);
      GEN_FINE_TUNE:    Z.FineTune    := Z.FineTune    + A.ShortAmount;
      GEN_COARSE_TUNE:  Z.CoarseTune  := Z.CoarseTune  + A.ShortAmount;
      GEN_SCALE_TUNING: Z.ScaleTuning := A.UShortAmount;
      GEN_ROOT_KEY_OVERRIDE: if A.ShortAmount >= 0 then Z.RootKey := A.ShortAmount;

      GEN_INITIAL_FILTER_FC: Z.FilterCents := Z.FilterCents + A.ShortAmount;
      GEN_INITIAL_FILTER_Q:  Z.FilterQDB   := Z.FilterQDB   + (A.UShortAmount / 10.0);

      GEN_START_ADDRS_OFFSET:       Z.StartOffset     := Z.StartOffset     + A.ShortAmount;
      GEN_END_ADDRS_OFFSET:         Z.EndOffset       := Z.EndOffset       + A.ShortAmount;
      GEN_STARTLOOP_ADDRS_OFFSET:   Z.LoopStartOffset := Z.LoopStartOffset + A.ShortAmount;
      GEN_ENDLOOP_ADDRS_OFFSET:     Z.LoopEndOffset   := Z.LoopEndOffset   + A.ShortAmount;
      GEN_START_ADDRS_COARSE_OFFSET: Z.StartOffset    := Z.StartOffset     + Int64(A.ShortAmount)*32768;
      GEN_END_ADDRS_COARSE_OFFSET:   Z.EndOffset      := Z.EndOffset       + Int64(A.ShortAmount)*32768;
      GEN_STARTLOOP_ADDRS_COARSE:   Z.LoopStartOffset := Z.LoopStartOffset + Int64(A.ShortAmount)*32768;
      GEN_ENDLOOP_ADDRS_COARSE:     Z.LoopEndOffset   := Z.LoopEndOffset   + Int64(A.ShortAmount)*32768;
    end;
  end;
end;

// Instrument-level zone application: SET semantics.
// Per SF2 spec, instrument generators SET (replace) the default value;
// the instrument local zone overrides the global zone for any generator present.
// Only sample address offsets stay additive (fine + coarse compose the total offset).
procedure TSF2.ApplyIgenSetToZone(BagIdx: Integer; var Z: TZone);
var g, GS, GE, si: Integer; Op: TUInt16; A: TSF2GenAmount; HaveSample: Boolean;
    BaseStart, BaseEnd, BaseLoopStart, BaseLoopEnd: Int64;
begin
  GS := FIbag[BagIdx].GenIdx;
  if BagIdx + 1 < FIbagN then GE := FIbag[BagIdx + 1].GenIdx else GE := FIgenN;
  si := -1; HaveSample := False;

  for g := GS to GE - 1 do
  begin
    Op := FIgen[g].Oper; A := FIgen[g].Amount;
    case Op of
      GEN_SAMPLE_ID: begin si := A.UShortAmount; HaveSample := (si >= 0) and (si < FShdN); end;
      GEN_ROOT_KEY_OVERRIDE: if A.ShortAmount >= 0 then Z.RootKey := A.ShortAmount;
      GEN_SAMPLE_MODES: Z.LoopMode := A.UShortAmount and 3;

      // Volume envelope — SET (local zone overrides global zone)
      GEN_VOL_ENV_DELAY:   Z.VolEnvDelayTC   := A.ShortAmount;
      GEN_VOL_ENV_ATTACK:  Z.VolEnvAttackTC  := A.ShortAmount;
      GEN_VOL_ENV_HOLD:    Z.VolEnvHoldTC    := A.ShortAmount;
      GEN_VOL_ENV_DECAY:   Z.VolEnvDecayTC   := A.ShortAmount;
      GEN_VOL_ENV_SUSTAIN: Z.VolEnvSustainCB := A.UShortAmount;
      GEN_VOL_ENV_RELEASE: Z.VolEnvReleaseTC := A.ShortAmount;
      GEN_KEY_TO_VOL_ENV_HOLD:  Z.KeyToVolHoldTC  := A.ShortAmount;
      GEN_KEY_TO_VOL_ENV_DECAY: Z.KeyToVolDecayTC := A.ShortAmount;

      // Modulation envelope — SET
      GEN_MOD_ENV_DELAY:   Z.ModEnvDelayTC   := A.ShortAmount;
      GEN_MOD_ENV_ATTACK:  Z.ModEnvAttackTC  := A.ShortAmount;
      GEN_MOD_ENV_HOLD:    Z.ModEnvHoldTC    := A.ShortAmount;
      GEN_MOD_ENV_DECAY:   Z.ModEnvDecayTC   := A.ShortAmount;
      GEN_MOD_ENV_SUSTAIN: Z.ModEnvSustainCB := A.UShortAmount;
      GEN_MOD_ENV_RELEASE: Z.ModEnvReleaseTC := A.ShortAmount;
      GEN_MOD_ENV_TO_PITCH:     Z.ModEnvToPitchC  := A.ShortAmount;
      GEN_MOD_ENV_TO_FILTER_FC: Z.ModEnvToFilterC := A.ShortAmount;

      // LFOs — SET
      GEN_MOD_LFO_DELAY:        Z.ModLFODelayTC  := A.ShortAmount;
      GEN_MOD_LFO_FREQ:         Z.ModLFOFreqHz8  := A.ShortAmount;
      GEN_MOD_LFO_TO_PITCH:     Z.ModLFOToPitch  := A.ShortAmount;
      GEN_MOD_LFO_TO_FILTER_FC: Z.ModLFOToFilter := A.ShortAmount;
      GEN_MOD_LFO_TO_VOLUME:    Z.ModLFOToVol    := A.ShortAmount;

      GEN_VIB_LFO_DELAY:        Z.VibLFODelayTC  := A.ShortAmount;
      GEN_VIB_LFO_FREQ:         Z.VibLFOFreqHz8  := A.ShortAmount;
      GEN_VIB_LFO_TO_PITCH:     Z.VibLFOToPitch  := A.ShortAmount;

      // Amplitude / pitch / filter — SET
      GEN_INITIAL_ATTENUATION: Z.AttenuationCB  := A.UShortAmount;
      GEN_PAN:                 Z.Pan            := A.ShortAmount / 500.0;
      GEN_FINE_TUNE:           Z.FineTune       := A.ShortAmount;
      GEN_COARSE_TUNE:         Z.CoarseTune     := A.ShortAmount;
      GEN_SCALE_TUNING:        Z.ScaleTuning    := A.UShortAmount;
      GEN_INITIAL_FILTER_FC:   Z.FilterCents    := A.ShortAmount;
      GEN_INITIAL_FILTER_Q:    Z.FilterQDB      := A.UShortAmount / 10.0;
      GEN_EXCLUSIVE_CLASS:     Z.ExclusiveClass := A.UShortAmount;

      // Sample address offsets — additive (fine + coarse compose total offset)
      GEN_START_ADDRS_OFFSET:        Z.StartOffset     := Z.StartOffset     + A.ShortAmount;
      GEN_END_ADDRS_OFFSET:          Z.EndOffset       := Z.EndOffset       + A.ShortAmount;
      GEN_STARTLOOP_ADDRS_OFFSET:    Z.LoopStartOffset := Z.LoopStartOffset + A.ShortAmount;
      GEN_ENDLOOP_ADDRS_OFFSET:      Z.LoopEndOffset   := Z.LoopEndOffset   + A.ShortAmount;
      GEN_START_ADDRS_COARSE_OFFSET: Z.StartOffset     := Z.StartOffset     + Int64(A.ShortAmount)*32768;
      GEN_END_ADDRS_COARSE_OFFSET:   Z.EndOffset       := Z.EndOffset       + Int64(A.ShortAmount)*32768;
      GEN_STARTLOOP_ADDRS_COARSE:    Z.LoopStartOffset := Z.LoopStartOffset + Int64(A.ShortAmount)*32768;
      GEN_ENDLOOP_ADDRS_COARSE:      Z.LoopEndOffset   := Z.LoopEndOffset   + Int64(A.ShortAmount)*32768;
    end;
  end;

  if HaveSample then
  begin
    BaseStart     := Int64(FShdr[si].Start);
    BaseEnd       := Int64(FShdr[si].End_);
    BaseLoopStart := Int64(FShdr[si].LoopStart);
    BaseLoopEnd   := Int64(FShdr[si].LoopEnd);

    Z.SampleStart := TUInt32(BaseStart     + Z.StartOffset);
    Z.SampleEnd   := TUInt32(BaseEnd       + Z.EndOffset);
    Z.LoopStart   := TUInt32(BaseLoopStart + Z.LoopStartOffset);
    Z.LoopEnd     := TUInt32(BaseLoopEnd   + Z.LoopEndOffset);
    Z.SampleRate  := FShdr[si].SampleRate;

    if Z.RootKey < 0 then Z.RootKey := FShdr[si].OriginalPitch;
    Z.PitchCorr := FShdr[si].PitchCorrect;
    Z.Valid := True;
  end;
end;

constructor TSF2.Create(const FileName: string);
  function RL16(S: TStream): TUInt16; var B: array[0..1] of Byte; begin S.ReadBuffer(B,2); Result := TUInt16(B[0]) or (TUInt16(B[1]) shl 8); end;
  function RL32(S: TStream): TUInt32; var B: array[0..3] of Byte; begin S.ReadBuffer(B,4); Result := TUInt32(B[0]) or (TUInt32(B[1]) shl 8) or (TUInt32(B[2]) shl 16) or (TUInt32(B[3]) shl 24); end;
  function RTag(S: TStream): string; var C: array[0..3] of Char; begin S.ReadBuffer(C,4); Result := C[0]+C[1]+C[2]+C[3]; end;
var S: TFileStream; Tag: string; CSize: TUInt32; SubEnd, PdtaEnd: Int64;
    SmplPos: Int64; SmplSize: TUInt32; i,N: Integer; W: TUInt16;
begin
  inherited Create;
  S := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    if RTag(S) <> 'RIFF' then raise Exception.Create('Not an SF2: missing RIFF');
    RL32(S);
    if RTag(S) <> 'sfbk' then raise Exception.Create('Not an SF2: missing sfbk');
    SmplPos := 0; SmplSize := 0;
    while S.Position + 8 <= S.Size do
    begin
      Tag := RTag(S); CSize := RL32(S); SubEnd := S.Position + CSize;
      if Tag = 'LIST' then
      begin
        Tag := RTag(S);
        if Tag = 'sdta' then
        begin
          while S.Position + 8 <= SubEnd do
          begin
            Tag := RTag(S); CSize := RL32(S);
            if Tag = 'smpl' then begin SmplPos := S.Position; SmplSize := CSize; S.Seek(CSize, soCurrent); end
            else S.Seek(CSize, soCurrent);
          end;
        end
        else if Tag = 'pdta' then
        begin
          PdtaEnd := SubEnd;
          while S.Position + 8 <= PdtaEnd do
          begin
            Tag := RTag(S); CSize := RL32(S);
            if Tag = 'phdr' then begin N := CSize div 38; FPhdrN := N; SetLength(FPhdr, N); for i:=0 to N-1 do S.ReadBuffer(FPhdr[i],38); end
            else if Tag = 'pbag' then begin N := CSize div 4; FPbagN := N; SetLength(FPbag, N); for i:=0 to N-1 do S.ReadBuffer(FPbag[i],4); end
            else if Tag = 'pmod' then S.Seek(CSize, soCurrent)
            else if Tag = 'pgen' then begin N := CSize div 4; FPgenN := N; SetLength(FPgen, N); for i:=0 to N-1 do S.ReadBuffer(FPgen[i],4); end
            else if Tag = 'inst' then begin N := CSize div 22; FInstN := N; SetLength(FInst, N); for i:=0 to N-1 do S.ReadBuffer(FInst[i],22); end
            else if Tag = 'ibag' then begin N := CSize div 4; FIbagN := N; SetLength(FIbag, N); for i:=0 to N-1 do S.ReadBuffer(FIbag[i],4); end
            else if Tag = 'imod' then S.Seek(CSize, soCurrent)
            else if Tag = 'igen' then begin N := CSize div 4; FIgenN := N; SetLength(FIgen, N); for i:=0 to N-1 do S.ReadBuffer(FIgen[i],4); end
            else if Tag = 'shdr' then begin N := CSize div 46; FShdN := N; SetLength(FShdr, N); for i:=0 to N-1 do S.ReadBuffer(FShdr[i],46); end
            else S.Seek(CSize, soCurrent);
          end;
        end
        else S.Seek(SubEnd, soBeginning);
      end
      else S.Seek(CSize, soCurrent);
    end;

    if SmplSize > 0 then
    begin
      FSmpCount := SmplSize div 2;
      SetLength(FSamples, FSmpCount);
      S.Position := SmplPos;
      for i := 0 to FSmpCount-1 do begin W := RL16(S); FSamples[i] := TInt16(W); end;
    end;
  finally S.Free; end;

  WriteLn(Format('SF2: %d presets, %d instruments, %d sample frames', [FPhdrN, FInstN, FSmpCount]));
end;

destructor TSF2.Destroy;
begin SetLength(FSamples, 0); inherited; end;

function TSF2.GetSample(P: TUInt32): TInt16;
begin if P < FSmpCount then Result := FSamples[P] else Result := 0; end;

function TSF2.FindZones(Bank, Prog, Key, Vel: Integer; out Zones: TZoneArray): Integer;

  procedure DefaultZone(var Z: TZone);
  begin
    FillChar(Z, SizeOf(Z), 0);
    Z.RootKey         := -1;
    Z.ScaleTuning     := 100;
    // Envelope defaults per SF2 spec (all in timecents)
    Z.VolEnvDelayTC   := -12000;
    Z.VolEnvAttackTC  := -12000;
    Z.VolEnvHoldTC    := -12000;
    Z.VolEnvDecayTC   := -12000;
    Z.VolEnvSustainCB := 0;       // 0 = full sustain
    Z.VolEnvReleaseTC := -12000;
    Z.ModEnvDelayTC   := -12000;
    Z.ModEnvAttackTC  := -12000;
    Z.ModEnvHoldTC    := -12000;
    Z.ModEnvDecayTC   := -12000;
    Z.ModEnvSustainCB := 0;
    Z.ModEnvReleaseTC := -12000;
    Z.ModLFODelayTC   := -12000;
    Z.ModLFOFreqHz8   := 0;       // 0 = 8.176 Hz (default)
    Z.VibLFODelayTC   := -12000;
    Z.VibLFOFreqHz8   := 0;
    Z.FilterCents     := 13500;   // default = fully open (~20 kHz)
    Z.FilterQDB       := 0.0;
    Z.Valid           := False;
  end;

  procedure AddZone(const Z: TZone);
  var N: Integer; begin N := Length(Zones); SetLength(Zones, N+1); Zones[N] := Z; end;

// Zone building follows the SF2 spec layering rules:
//   Instrument level (global then local): generators SET values (local overrides global).
//   Preset level (global then local): generators ADD offsets on top of the instrument result.
var ph, pb, pg, ib: Integer; BagS, BagE, IBagS, IBagE: Integer; InstIdx: Integer; GS, GE: Integer;
    KeyLo, KeyHi, VelLo, VelHi: Integer; HasKey, HasVel, HasSmp: Boolean;
    Op: TUInt16; A: TSF2GenAmount;
    InstGlobalZ, CandZ: TZone;
    HasInstGlobal: Boolean;
    PresetGlobalBag, PresetLocalBag: Integer;
begin
  Result := 0; SetLength(Zones, 0);
  for ph := 0 to FPhdrN - 2 do
  begin
    if (FPhdr[ph].Bank <> Bank) or (FPhdr[ph].Preset <> Prog) then Continue;
    BagS := FPhdr[ph].BagIdx; BagE := FPhdr[ph + 1].BagIdx;

    // First pass: locate the preset global zone bag (the one without GEN_INSTRUMENT)
    PresetGlobalBag := -1;
    for pb := BagS to BagE - 1 do
    begin
      GS := FPbag[pb].GenIdx; if pb + 1 < FPbagN then GE := FPbag[pb + 1].GenIdx else GE := FPgenN;
      InstIdx := -1;
      for pg := GS to GE - 1 do
        if FPgen[pg].Oper = GEN_INSTRUMENT then begin InstIdx := FPgen[pg].Amount.UShortAmount; Break; end;
      if InstIdx < 0 then begin PresetGlobalBag := pb; Break; end;
    end;

    // Second pass: process each preset zone that references an instrument
    for pb := BagS to BagE - 1 do
    begin
      GS := FPbag[pb].GenIdx; if pb + 1 < FPbagN then GE := FPbag[pb + 1].GenIdx else GE := FPgenN;
      KeyLo := 0; KeyHi := 127; VelLo := 0; VelHi := 127;
      HasKey := False; HasVel := False; InstIdx := -1;

      for pg := GS to GE - 1 do
      begin
        Op := FPgen[pg].Oper; A := FPgen[pg].Amount;
        case Op of
          GEN_KEY_RANGE:  begin KeyLo := A.Lo; KeyHi := A.Hi; HasKey := True; end;
          GEN_VEL_RANGE:  begin VelLo := A.Lo; VelHi := A.Hi; HasVel := True; end;
          GEN_INSTRUMENT: InstIdx := A.UShortAmount;
        end;
      end;

      if InstIdx < 0 then Continue;  // global zone — already found above
      if HasKey and ((Key < KeyLo) or (Key > KeyHi)) then Continue;
      if HasVel and ((Vel < VelLo) or (Vel > VelHi)) then Continue;
      if InstIdx >= FInstN - 1 then Continue;

      PresetLocalBag := pb;

      // Build instrument global zone starting from SF2 defaults
      IBagS := FInst[InstIdx].BagIdx; IBagE := FInst[InstIdx + 1].BagIdx;
      DefaultZone(InstGlobalZ); HasInstGlobal := False;

      for ib := IBagS to IBagE - 1 do
      begin
        GS := FIbag[ib].GenIdx; if ib + 1 < FIbagN then GE := FIbag[ib + 1].GenIdx else GE := FIgenN;
        KeyLo := 0; KeyHi := 127; VelLo := 0; VelHi := 127;
        HasKey := False; HasVel := False; HasSmp := False;

        for pg := GS to GE - 1 do
        begin
          Op := FIgen[pg].Oper; A := FIgen[pg].Amount;
          case Op of
            GEN_KEY_RANGE: begin KeyLo := A.Lo; KeyHi := A.Hi; HasKey := True; end;
            GEN_VEL_RANGE: begin VelLo := A.Lo; VelHi := A.Hi; HasVel := True; end;
            GEN_SAMPLE_ID: HasSmp := True;
          end;
        end;

        if not HasSmp then
        begin
          // Instrument global zone: SET into InstGlobalZ (starts from SF2 defaults)
          DefaultZone(InstGlobalZ);
          ApplyIgenSetToZone(ib, InstGlobalZ);
          HasInstGlobal := True;
          Continue;
        end;
        if HasKey and ((Key < KeyLo) or (Key > KeyHi)) then Continue;
        if HasVel and ((Vel < VelLo) or (Vel > VelHi)) then Continue;

        // Start candidate zone from instrument global (or SF2 defaults if none)
        if HasInstGlobal then CandZ := InstGlobalZ else DefaultZone(CandZ);
        // Instrument local zone: SET (overrides global for any generator present)
        ApplyIgenSetToZone(ib, CandZ);

        // Now apply preset-level generators as additive offsets on top
        if PresetGlobalBag >= 0 then ApplyPgenToZone(PresetGlobalBag, CandZ);
        ApplyPgenToZone(PresetLocalBag, CandZ);

        if not CandZ.Valid then Continue;
        if CandZ.SampleEnd <= CandZ.SampleStart then Continue;
        if CandZ.RootKey < 0 then CandZ.RootKey := 60;
        if CandZ.Pan < -1.0 then CandZ.Pan := -1.0;
        if CandZ.Pan > 1.0 then CandZ.Pan := 1.0;
        if CandZ.VolEnvSustainCB < 0 then CandZ.VolEnvSustainCB := 0;
        if CandZ.VolEnvSustainCB > 1000 then CandZ.VolEnvSustainCB := 1000;
        if CandZ.ModEnvSustainCB < 0 then CandZ.ModEnvSustainCB := 0;
        if CandZ.ModEnvSustainCB > 1000 then CandZ.ModEnvSustainCB := 1000;

        AddZone(CandZ);
      end;
    end;
    Result := Length(Zones); Exit;
  end;
  if (Result = 0) and (Bank > 0) then Result := FindZones(0, Prog, Key, Vel, Zones);
end;

// ===========================================================================
//  MIDI + VOICE
// ===========================================================================

type
  TMidiEvent = record
    AbsTick   : Int64;
    Status    : Byte;
    Data1     : Byte;
    Data2     : Byte;
    MetaTempo : TUInt32;
  end;
  TMidiEventArray = array of TMidiEvent;

  TEnvPhase = (epDelay, epAttack, epHold, epDecay, epSustain, epRelease, epDone);

  TVoice = record
    Active       : Boolean;
    Note         : Byte;
    Ch           : Byte;
    Zone         : TZone;

    // Sample playback
    Pos          : Double;
    PosInc       : Double;        // base pitch increment (without LFO/env mod)
    BaseCents    : Double;        // cents offset from root (for pitch mod recalc)

    // Volume envelope
    VolPhase     : TEnvPhase;
    VolLevel     : Double;
    VolTimer     : Double;
    VolRelLevel  : Double;
    VolDelaySec  : Double;
    VolAttackSec : Double;
    VolHoldSec   : Double;        // key-scaled hold time
    VolDecaySec  : Double;        // key-scaled decay time
    VolSustain   : Double;        // linear sustain level
    VolRelSec    : Double;

    // Modulation envelope
    ModPhase     : TEnvPhase;
    ModLevel     : Double;        // 0..1
    ModTimer     : Double;
    ModRelLevel  : Double;
    ModDelaySec  : Double;
    ModAttackSec : Double;
    ModHoldSec   : Double;
    ModDecaySec  : Double;
    ModSustain   : Double;
    ModRelSec    : Double;

    // LFOs (phase in seconds, sign = triangle wave)
    ModLFOTime   : Double;        // accumulates; LFO starts after delay
    VibLFOTime   : Double;

    KeyReleased    : Boolean;
    ExclusiveClass : Integer;
    VelGain        : Double;
    GainL        : Double;
    GainR        : Double;

    // Biquad filter state (two biquad sections = 4-pole)
    BQ1x1, BQ1x2 : Double;
    BQ1y1, BQ1y2 : Double;
    BQ2x1, BQ2x2 : Double;
    BQ2y1, BQ2y2 : Double;
    LastFc       : Double;        // cached last cutoff for coeff reuse
    // Biquad coefficients
    BQb0, BQb1, BQb2 : Double;
    BQa1, BQa2       : Double;
  end;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function ReadVarLen(S: TStream; out V: TUInt32): Boolean;
var B: Byte; Sh: Integer;
begin
  V := 0; Sh := 0; Result := False;
  repeat
    if S.Read(B,1) <> 1 then Exit;
    V := (V shl 7) or (B and $7F);
    Inc(Sh,7); if Sh > 28 then Exit;
  until (B and $80) = 0;
  Result := True;
end;

function ReadBE32(S: TStream): TUInt32;
var B: array[0..3] of Byte;
begin S.ReadBuffer(B,4); Result := (TUInt32(B[0]) shl 24) or (TUInt32(B[1]) shl 16) or (TUInt32(B[2]) shl 8) or TUInt32(B[3]); end;

function ReadBE16(S: TStream): TUInt16;
var B: array[0..1] of Byte;
begin S.ReadBuffer(B,2); Result := (TUInt16(B[0]) shl 8) or TUInt16(B[1]); end;

// Compute biquad low-pass coefficients (2-pole Butterworth-ish)
// fc in Hz, Q dimensionless, SR = sample rate
procedure BiquadLP(fc, Q, SR: Double; out b0,b1,b2,a1,a2: Double);
var w0, alpha, cosw0: Double;
begin
  if fc >= SR * 0.499 then
  begin
    // bypass: identity filter
    b0 := 1.0; b1 := 0.0; b2 := 0.0; a1 := 0.0; a2 := 0.0;
    Exit;
  end;
  if Q < 0.5 then Q := 0.5;  // prevent under-damped instability
  w0 := 2.0 * Pi * fc / SR;
  cosw0 := Cos(w0);
  alpha := Sin(w0) / (2.0 * Q);
  b0 := (1.0 - cosw0) / 2.0;
  b1 := 1.0 - cosw0;
  b2 := (1.0 - cosw0) / 2.0;
  // normalize
  b0 := b0 / (1.0 + alpha);
  b1 := b1 / (1.0 + alpha);
  b2 := b2 / (1.0 + alpha);
  a1 := (-2.0 * cosw0) / (1.0 + alpha);
  a2 := (1.0 - alpha) / (1.0 + alpha);
end;

procedure ParseTrack(S: TStream; TrackLen: TUInt32; var Ev: TMidiEventArray; var EvN: Integer);
var EndPos: Int64; Delta: TUInt32; AbsTick: Int64;
    Status, RunStatus, D1, D2, Meta: Byte; MLen, Tempo: TUInt32;
    E: TMidiEvent; i: Integer;
begin
  EndPos := S.Position + TrackLen; AbsTick := 0; RunStatus := 0;
  while S.Position < EndPos do
  begin
    if not ReadVarLen(S, Delta) then Break;
    Inc(AbsTick, Delta);
    S.ReadBuffer(Status, 1);
    if Status = $FF then
    begin
      S.ReadBuffer(Meta, 1); ReadVarLen(S, MLen);
      if Meta = $51 then
      begin
        if MLen >= 3 then
        begin
          Tempo := 0;
          for i := 0 to 2 do begin S.ReadBuffer(D1,1); Tempo := (Tempo shl 8) or D1; end;
          Dec(MLen,3); if MLen > 0 then S.Seek(MLen, soCurrent);
          if EvN >= Length(Ev) then SetLength(Ev, Length(Ev)+512);
          FillChar(E, SizeOf(E), 0);
          E.AbsTick := AbsTick; E.MetaTempo := Tempo;
          Ev[EvN] := E; Inc(EvN);
        end else S.Seek(MLen, soCurrent);
      end else S.Seek(MLen, soCurrent);
      RunStatus := 0;
    end
    else if (Status = $F0) or (Status = $F7) then
    begin
      ReadVarLen(S, MLen); S.Seek(MLen, soCurrent); RunStatus := 0;
    end
    else
    begin
      if (Status and $80) <> 0 then
      begin
        RunStatus := Status;
        if EvN >= Length(Ev) then SetLength(Ev, Length(Ev)+512);
        FillChar(E, SizeOf(E), 0); E.AbsTick := AbsTick; E.Status := Status;
        case (Status and $F0) of
          $80,$90,$A0,$B0,$E0: begin S.ReadBuffer(D1,1); S.ReadBuffer(D2,1); E.Data1:=D1; E.Data2:=D2; end;
          $C0,$D0: begin S.ReadBuffer(D1,1); E.Data1:=D1; E.Data2:=0; end;
        else raise Exception.CreateFmt('Unsupported MIDI status $%.2x', [Status]); end;
        Ev[EvN] := E; Inc(EvN);
      end
      else
      begin
        if RunStatus = 0 then raise Exception.Create('Running status used before any channel status');
        if EvN >= Length(Ev) then SetLength(Ev, Length(Ev)+512);
        FillChar(E, SizeOf(E), 0); E.AbsTick := AbsTick; E.Status := RunStatus; E.Data1 := Status;
        case (RunStatus and $F0) of
          $80,$90,$A0,$B0,$E0: begin S.ReadBuffer(D2,1); E.Data2:=D2; end;
          $C0,$D0: ;
        else raise Exception.CreateFmt('Unsupported running status $%.2x', [RunStatus]); end;
        Ev[EvN] := E; Inc(EvN);
      end;
    end;
  end;
  if S.Position < EndPos then S.Seek(EndPos - S.Position, soCurrent);
end;

procedure SortEvents(var Ev: TMidiEventArray; N: Integer);
var i,j: Integer; T: TMidiEvent;
begin
  for i:=1 to N-1 do
  begin
    T:=Ev[i]; j:=i-1;
    while (j>=0) and (Ev[j].AbsTick > T.AbsTick) do begin Ev[j+1]:=Ev[j]; Dec(j); end;
    Ev[j+1]:=T;
  end;
end;

procedure WriteWavHeader(S: TStream; NumSamples: Int64);
var D32: TUInt32; D16: TUInt16;
  procedure W32(V: TUInt32); begin D32:=V; S.WriteBuffer(D32,4); end;
  procedure W16(V: TUInt16); begin D16:=V; S.WriteBuffer(D16,2); end;
var DataSize: TUInt32;
begin
  DataSize := NumSamples * NUM_CHANNELS * (BIT_DEPTH div 8);
  S.WriteBuffer(PChar('RIFF')^,4); W32(36 + DataSize);
  S.WriteBuffer(PChar('WAVE')^,4);
  S.WriteBuffer(PChar('fmt ')^,4); W32(16);
  W16(1); W16(NUM_CHANNELS); W32(SAMPLE_RATE);
  W32(SAMPLE_RATE * NUM_CHANNELS * (BIT_DEPTH div 8));
  W16(NUM_CHANNELS * (BIT_DEPTH div 8)); W16(BIT_DEPTH);
  S.WriteBuffer(PChar('data')^,4); W32(DataSize);
end;

// ---------------------------------------------------------------------------
// SYNTHESIS
// ---------------------------------------------------------------------------
procedure Synthesize(SF: TSF2; const Events: TMidiEventArray; EvCount: Integer; PPQ: Word; OutFile: TFileStream);
const TAIL_SECS = 3.0; BUF_FRAMES = 512;
var
  Voices: array[0..MAX_VOICES-1] of TVoice;
  ChSustain   : array[0..MAX_MIDI_CH-1] of Boolean;
  ChProg, ChBank, ChVolume, ChExpr, ChPan, ChPitchBend, ChBendRange: array[0..MAX_MIDI_CH-1] of Integer;
  ChModWheel  : array[0..MAX_MIDI_CH-1] of Integer;
  NVoices     : Integer;
  CurTempo, TempoRefTick, TempoRefSample, SampleTime, TotalSamples, LastTick : Int64;
  SecsPerTick : Double;
  i, ch: Integer; ES: Int64; St, CC: Byte; BendVal: Integer;
  PreRefTick, PreRefSample: Int64; PreSPT: Double; PreTempo: TUInt32;
  TailRendered, MaxTailSamples: Int64; AnyActive: Boolean;

  procedure UpdateSecsPerTick;
  begin SecsPerTick := (CurTempo / 1000000.0) / PPQ; end;

  function T2S(Ticks: Int64): Int64;
  begin Result := TempoRefSample + Round((Ticks - TempoRefTick) * SecsPerTick * SAMPLE_RATE); end;

  // Compute PosInc for a voice given current modulation
  function CalcPosInc(const V: TVoice; ExtraCents: Double): Double;
  var Cents: Double;
  begin
    Cents := V.BaseCents + ExtraCents + (ChPitchBend[V.Ch] / 8192.0) * ChBendRange[V.Ch] * 100.0;
    Result := Power(2.0, Cents / 1200.0) * V.Zone.SampleRate / SAMPLE_RATE;
  end;

  procedure StartVoiceFromZone(Ch, Note, Vel: Integer; const Z: TZone);
  var v, Free: Integer; Cents, Atten, VG, ChGain, PanFrac, GL, GR: Double;
      KeyDiff: Integer;
  begin
    // Exclusive class (gen 57): kill all active voices on this channel with same class
    if Z.ExclusiveClass > 0 then
      for v := 0 to NVoices-1 do
        if Voices[v].Active and (Voices[v].Ch = Ch)
           and (Voices[v].ExclusiveClass = Z.ExclusiveClass)
           and (Voices[v].VolPhase <> epDone) then
        begin
          Voices[v].VolPhase    := epRelease;
          Voices[v].VolRelLevel := Voices[v].VolLevel;
          Voices[v].VolRelSec   := 0.005;   // 5 ms fast cut-off
          Voices[v].VolTimer    := 0.0;
          Voices[v].ModPhase    := epRelease;
          Voices[v].ModRelLevel := Voices[v].ModLevel;
          Voices[v].ModRelSec   := 0.005;
          Voices[v].ModTimer    := 0.0;
        end;

    Free := -1;
    for v := 0 to NVoices-1 do if not Voices[v].Active then begin Free := v; Break; end;
    if Free < 0 then
    begin
      if NVoices < MAX_VOICES then begin Free := NVoices; Inc(NVoices); end
      else begin Free := 0; for v := 1 to NVoices-1 do if Ord(Voices[v].VolPhase) > Ord(Voices[Free].VolPhase) then Free := v; end;
    end;

    // Base cents from note/root difference
    Cents := (Note - Z.RootKey) * Z.ScaleTuning + Z.CoarseTune * 100.0 + Z.FineTune + Z.PitchCorr;
    Atten := Power(10.0, -(Z.AttenuationCB / 10.0) / 20.0);
    VG    := (Vel / 127.0) * (Vel / 127.0);
    ChGain := (ChVolume[Ch] / 127.0) * (ChExpr[Ch] / 127.0);
    PanFrac := Z.Pan + (ChPan[Ch] - 64) / 63.0;
    if PanFrac < -1 then PanFrac := -1; if PanFrac > 1 then PanFrac := 1;
    GL := Cos((PanFrac + 1.0) * 0.25 * Pi);
    GR := Sin((PanFrac + 1.0) * 0.25 * Pi);

    // Key-scaled envelope times
    KeyDiff := Note - 60;
    // Key scaling: HoldSec and DecaySec scale by keyToXxx timecents per semitone from 60

    FillChar(Voices[Free], SizeOf(TVoice), 0);
    Voices[Free].Active      := True;
    Voices[Free].Note        := Note;
    Voices[Free].Ch          := Ch;
    Voices[Free].Zone        := Z;
    Voices[Free].Pos         := Z.SampleStart;
    Voices[Free].BaseCents   := Cents;
    Voices[Free].PosInc      := Power(2.0, (Cents + (ChPitchBend[Ch] / 8192.0) * ChBendRange[Ch] * 100.0) / 1200.0) * Z.SampleRate / SAMPLE_RATE;

    // Volume envelope
    Voices[Free].VolPhase    := epDelay;
    Voices[Free].VolTimer    := 0.0;
    Voices[Free].VolLevel    := 0.0;
    Voices[Free].VolDelaySec  := TC2Sec(Z.VolEnvDelayTC);
    Voices[Free].VolAttackSec := TC2Sec(Z.VolEnvAttackTC);
    Voices[Free].VolHoldSec   := TC2Sec(Z.VolEnvHoldTC + KeyDiff * Z.KeyToVolHoldTC);
    Voices[Free].VolDecaySec  := TC2Sec(Z.VolEnvDecayTC + KeyDiff * Z.KeyToVolDecayTC);
    Voices[Free].VolSustain   := CB2Lin(Z.VolEnvSustainCB);
    Voices[Free].VolRelSec    := TC2Sec(Z.VolEnvReleaseTC);

    // Modulation envelope
    Voices[Free].ModPhase    := epDelay;
    Voices[Free].ModTimer    := 0.0;
    Voices[Free].ModLevel    := 0.0;
    Voices[Free].ModDelaySec  := TC2Sec(Z.ModEnvDelayTC);
    Voices[Free].ModAttackSec := TC2Sec(Z.ModEnvAttackTC);
    Voices[Free].ModHoldSec   := TC2Sec(Z.ModEnvHoldTC);
    Voices[Free].ModDecaySec  := TC2Sec(Z.ModEnvDecayTC);
    Voices[Free].ModSustain   := CB2Lin(Z.ModEnvSustainCB);
    Voices[Free].ModRelSec    := TC2Sec(Z.ModEnvReleaseTC);

    // LFO timers start negative (delay period)
    Voices[Free].ModLFOTime  := -TC2Sec(Z.ModLFODelayTC);
    Voices[Free].VibLFOTime  := -TC2Sec(Z.VibLFODelayTC);

    Voices[Free].ExclusiveClass := Z.ExclusiveClass;
    Voices[Free].VelGain     := Atten * VG;
    Voices[Free].GainL       := GL * ChGain;
    Voices[Free].GainR       := GR * ChGain;
    Voices[Free].LastFc      := -1.0;  // force recompute
  end;

  procedure DoNoteOn(Ch, Note, Vel: Integer);
  var Zones: TZoneArray; Count, zi, Bank, Prog: Integer;
  begin
    if Ch = 9 then Bank := 128 else Bank := ChBank[Ch];
    Prog := ChProg[Ch];
    Count := SF.FindZones(Bank, Prog, Note, Vel, Zones);
    if Count <= 0 then Exit;
    for zi := 0 to Count-1 do StartVoiceFromZone(Ch, Note, Vel, Zones[zi]);
  end;

  procedure DoNoteOff(Ch, Note: Integer);
  var v: Integer;
  begin
    for v := 0 to NVoices-1 do
      if Voices[v].Active and (Voices[v].Note = Note) and (Voices[v].Ch = Ch)
         and (Voices[v].VolPhase <> epRelease) and (Voices[v].VolPhase <> epDone) then
      begin
        if ChSustain[Ch] then
          Voices[v].KeyReleased := True
        else
        begin
          Voices[v].KeyReleased := False;
          Voices[v].VolPhase    := epRelease;
          Voices[v].VolRelLevel := Voices[v].VolLevel;
          Voices[v].VolTimer    := 0.0;
          Voices[v].ModPhase    := epRelease;
          Voices[v].ModRelLevel := Voices[v].ModLevel;
          Voices[v].ModTimer    := 0.0;
        end;
      end;
  end;

  procedure UpdateChannelGain(Ch: Integer);
  var v: Integer; ChGain, PanFrac, GL, GR: Double;
  begin
    ChGain := (ChVolume[Ch] / 127.0) * (ChExpr[Ch] / 127.0);
    for v := 0 to NVoices-1 do
      if Voices[v].Active and (Voices[v].Ch = Ch) then
      begin
        PanFrac := Voices[v].Zone.Pan + (ChPan[Ch] - 64) / 63.0;
        if PanFrac < -1.0 then PanFrac := -1.0; if PanFrac > 1.0 then PanFrac := 1.0;
        GL := Cos((PanFrac + 1.0) * 0.25 * Pi);
        GR := Sin((PanFrac + 1.0) * 0.25 * Pi);
        Voices[v].GainL := GL * ChGain;
        Voices[v].GainR := GR * ChGain;
      end;
  end;

  procedure UpdatePitchBend(Ch: Integer);
  var v: Integer;
  begin
    for v := 0 to NVoices-1 do
      if Voices[v].Active and (Voices[v].Ch = Ch) then
        Voices[v].PosInc := Power(2.0,
          (Voices[v].BaseCents + (ChPitchBend[Ch] / 8192.0) * ChBendRange[Ch] * 100.0) / 1200.0)
          * Voices[v].Zone.SampleRate / SAMPLE_RATE;
  end;

  // Advance an envelope one sample; returns current level
  function AdvanceEnv(var Phase: TEnvPhase; var Level, Timer, RelLevel: Double;
                      DelaySec, AttackSec, HoldSec, DecaySec, SustainLin, ReleaseSec, DT: Double): Double;
  begin
    Timer := Timer + DT;
    case Phase of
      epDelay:
        begin
          Level := 0.0;
          if Timer >= DelaySec then begin Phase := epAttack; Timer := 0.0; end;
        end;
      epAttack:
        begin
          if AttackSec <= 0.001 then Level := 1.0
          else Level := Timer / AttackSec;
          if Level >= 1.0 then begin Level := 1.0; Phase := epHold; Timer := 0.0; end;
        end;
      epHold:
        begin
          Level := 1.0;
          if Timer >= HoldSec then begin Phase := epDecay; Timer := 0.0; end;
        end;
      epDecay:
        begin
          // SF2 spec: decay is linear in dB = exponential in amplitude
          if DecaySec <= 0.001 then Level := SustainLin
          else Level := Power(Max(SustainLin, 1e-7), Min(1.0, Timer / DecaySec));
          if Timer >= DecaySec then begin Level := SustainLin; Phase := epSustain; end;
        end;
      epSustain:
        Level := SustainLin;
      epRelease:
        begin
          // SF2 spec: release is linear in dB (exponential amplitude decay to -96 dB)
          if ReleaseSec <= 0.001 then Level := 0.0
          else Level := RelLevel * Power(10.0, -4.8 * Timer / ReleaseSec);
          if (Level < 1e-5) or (Timer >= ReleaseSec) then begin Level := 0.0; Phase := epDone; end;
        end;
      epDone:
        Level := 0.0;
    end;
    Result := Level;
  end;

  procedure RenderBlock(Count: Int64);
  var
    BufL, BufR   : array[0..BUF_FRAMES-1] of Double;
    Out16        : array[0..BUF_FRAMES*2-1] of TInt16;
    Rem          : Int64;
    NumFrames, Frame, v, OI: Integer;
    VolEnv, ModEnv, DT  : Double;
    Frac, RawSnd, Snd   : Double;
    S0, S1       : TInt16;
    SmpIdx       : TUInt32;
    LL           : TUInt32;
    SL, SR       : Double;
    Looping      : Boolean;
    ModLFOVal, VibLFOVal: Double;
    ModLFOFreq, VibLFOFreq: Double;
    PitchModCents, FilterModCents, VolumeModDB: Double;
    fc, Q        : Double;
    curPosInc    : Double;
    FilterCentsTotal: Double;
    FilterBypassed: Boolean;
    tmp          : Double;
  begin
    DT := 1.0 / SAMPLE_RATE;
    Rem := Count;
    while Rem > 0 do
    begin
      if Rem > BUF_FRAMES then NumFrames := BUF_FRAMES else NumFrames := Integer(Rem);
      FillChar(BufL, NumFrames * SizeOf(Double), 0);
      FillChar(BufR, NumFrames * SizeOf(Double), 0);

      for v := 0 to NVoices-1 do
        if Voices[v].Active then
          for Frame := 0 to NumFrames-1 do
          begin
            // --- Volume envelope ---
            VolEnv := AdvanceEnv(
              Voices[v].VolPhase, Voices[v].VolLevel, Voices[v].VolTimer, Voices[v].VolRelLevel,
              Voices[v].VolDelaySec,
              Voices[v].VolAttackSec, Voices[v].VolHoldSec, Voices[v].VolDecaySec,
              Voices[v].VolSustain, Voices[v].VolRelSec, DT);

            if Voices[v].VolPhase = epDone then
            begin
              Voices[v].Active := False;
              Break;
            end;

            // --- Modulation envelope ---
            ModEnv := AdvanceEnv(
              Voices[v].ModPhase, Voices[v].ModLevel, Voices[v].ModTimer, Voices[v].ModRelLevel,
              Voices[v].ModDelaySec,
              Voices[v].ModAttackSec, Voices[v].ModHoldSec, Voices[v].ModDecaySec,
              Voices[v].ModSustain, Voices[v].ModRelSec, DT);

            // --- LFOs ---
            // ModLFO: triangle wave
            ModLFOFreq := LFOFreq(Voices[v].Zone.ModLFOFreqHz8);
            if Voices[v].ModLFOTime < 0.0 then
            begin
              Voices[v].ModLFOTime := Voices[v].ModLFOTime + DT;
              ModLFOVal := 0.0;
            end else
            begin
              Voices[v].ModLFOTime := Voices[v].ModLFOTime + DT;
              // Triangle: 2 * |frac - 0.5| * 2 - 1  (range -1..1)
              tmp := ModLFOFreq * Voices[v].ModLFOTime;
              tmp := tmp - Floor(tmp);  // fractional part 0..1
              ModLFOVal := 2.0 * (2.0 * Abs(tmp - 0.5) - 0.5);  // -1..1
            end;

            // VibLFO: sine wave (vibrato)
            VibLFOFreq := LFOFreq(Voices[v].Zone.VibLFOFreqHz8);
            if Voices[v].VibLFOTime < 0.0 then
            begin
              Voices[v].VibLFOTime := Voices[v].VibLFOTime + DT;
              VibLFOVal := 0.0;
            end else
            begin
              Voices[v].VibLFOTime := Voices[v].VibLFOTime + DT;
              VibLFOVal := Sin(2.0 * Pi * VibLFOFreq * Voices[v].VibLFOTime);
            end;

            // Modulation wheel scales vibLFO to pitch (standard GM behavior)
            // ModWheel (CC1) adds up to 50 cents of vibrato when fully pressed
            VibLFOVal := VibLFOVal * (1.0 + ChModWheel[Voices[v].Ch] / 127.0 * 0.5);

            // --- Compute pitch modulation ---
            PitchModCents :=
              VibLFOVal * Voices[v].Zone.VibLFOToPitch +
              ModLFOVal * Voices[v].Zone.ModLFOToPitch +
              ModEnv    * Voices[v].Zone.ModEnvToPitchC;

            // --- Compute filter modulation ---
            FilterModCents :=
              ModLFOVal * Voices[v].Zone.ModLFOToFilter +
              ModEnv    * Voices[v].Zone.ModEnvToFilterC;

            // --- Volume modulation (tremolo) in dB ---
            VolumeModDB := ModLFOVal * (Voices[v].Zone.ModLFOToVol / 10.0); // centibels → dB

            // --- Update PosInc with pitch mods if nonzero ---
            if Abs(PitchModCents) > 0.01 then
              curPosInc := Power(2.0, (Voices[v].BaseCents + PitchModCents
                + (ChPitchBend[Voices[v].Ch] / 8192.0) * ChBendRange[Voices[v].Ch] * 100.0)
                / 1200.0) * Voices[v].Zone.SampleRate / SAMPLE_RATE
            else
              curPosInc := Voices[v].PosInc;

            // --- Sample interpolation ---
            SmpIdx := Trunc(Voices[v].Pos);
            Frac   := Voices[v].Pos - SmpIdx;
            S0     := SF.GetSample(SmpIdx);
            S1     := SF.GetSample(SmpIdx + 1);
            RawSnd := (S0 + Frac * (S1 - S0)) / 32768.0;

            // Apply envelopes and gains
            RawSnd := RawSnd * VolEnv * Voices[v].VelGain;
            if VolumeModDB <> 0.0 then
              RawSnd := RawSnd * Power(10.0, VolumeModDB / 20.0);

            // --- Filter ---
            FilterCentsTotal := Voices[v].Zone.FilterCents + FilterModCents;
            if FilterCentsTotal < 100 then FilterCentsTotal := 100;

            // Bypass filter if cutoff is at/near default open value
            FilterBypassed := FilterCentsTotal >= 13400;

            if not FilterBypassed then
            begin
              // Convert cents to Hz: fc = 8.176 * 2^(cents/1200)
              fc := 8.176 * Power(2.0, FilterCentsTotal / 1200.0);
              if fc > SAMPLE_RATE * 0.499 then
                FilterBypassed := True
              else
              begin
                // Only recompute coefficients when fc changes meaningfully
                if Abs(fc - Voices[v].LastFc) > fc * 0.01 then
                begin
                  Voices[v].LastFc := fc;
                  // FilterQDB is in dB (centibels/10); Q = 10^(dB/20)
                  Q := Power(10.0, Voices[v].Zone.FilterQDB / 20.0);
                  if Q < 0.5 then Q := 0.5; if Q > 20.0 then Q := 20.0;
                  BiquadLP(fc, Q, SAMPLE_RATE,
                    Voices[v].BQb0, Voices[v].BQb1, Voices[v].BQb2,
                    Voices[v].BQa1, Voices[v].BQa2);
                end;
                // Apply biquad filter (two cascaded sections = 4-pole)
                Snd := Voices[v].BQb0 * RawSnd + Voices[v].BQb1 * Voices[v].BQ1x1 + Voices[v].BQb2 * Voices[v].BQ1x2
                       - Voices[v].BQa1 * Voices[v].BQ1y1 - Voices[v].BQa2 * Voices[v].BQ1y2;
                Voices[v].BQ1x2 := Voices[v].BQ1x1; Voices[v].BQ1x1 := RawSnd;
                Voices[v].BQ1y2 := Voices[v].BQ1y1; Voices[v].BQ1y1 := Snd;
                RawSnd := Snd;
                Snd := Voices[v].BQb0 * RawSnd + Voices[v].BQb1 * Voices[v].BQ2x1 + Voices[v].BQb2 * Voices[v].BQ2x2
                       - Voices[v].BQa1 * Voices[v].BQ2y1 - Voices[v].BQa2 * Voices[v].BQ2y2;
                Voices[v].BQ2x2 := Voices[v].BQ2x1; Voices[v].BQ2x1 := RawSnd;
                Voices[v].BQ2y2 := Voices[v].BQ2y1; Voices[v].BQ2y1 := Snd;
                RawSnd := Snd;
              end;
            end;

            BufL[Frame] := BufL[Frame] + RawSnd * Voices[v].GainL;
            BufR[Frame] := BufR[Frame] + RawSnd * Voices[v].GainR;

            // Advance sample position
            Voices[v].Pos := Voices[v].Pos + curPosInc;

            Looping := (Voices[v].Zone.LoopMode = 1) or
                       ((Voices[v].Zone.LoopMode = 3) and
                        (Voices[v].VolPhase <> epRelease) and (Voices[v].VolPhase <> epDone));

            if Looping and (Voices[v].Zone.LoopEnd > Voices[v].Zone.LoopStart) then
            begin
              if Voices[v].Pos >= Double(Voices[v].Zone.LoopEnd) then
              begin
                LL := Voices[v].Zone.LoopEnd - Voices[v].Zone.LoopStart;
                if LL > 0 then
                  while Voices[v].Pos >= Double(Voices[v].Zone.LoopEnd) do
                    Voices[v].Pos := Voices[v].Pos - Double(LL);
              end;
            end
            else if Voices[v].Pos >= Double(Voices[v].Zone.SampleEnd) then
            begin
              Voices[v].Active := False;
              Voices[v].VolPhase := epDone;
              Break;
            end;
          end;  // for Frame

      // Convert buffer to 16-bit
      OI := 0;
      for Frame := 0 to NumFrames-1 do
      begin
        SL := BufL[Frame]; SR := BufR[Frame];
        if SL > 1.0 then SL := 1.0 else if SL < -1.0 then SL := -1.0;
        if SR > 1.0 then SR := 1.0 else if SR < -1.0 then SR := -1.0;
        Out16[OI]   := Round(SL * 32767.0);
        Out16[OI+1] := Round(SR * 32767.0);
        Inc(OI, 2);
      end;
      OutFile.WriteBuffer(Out16, NumFrames * 2 * SizeOf(TInt16));
      Dec(Rem, NumFrames);
    end;  // while Rem > 0
  end;

begin
  CurTempo := 500000; NVoices := 0; SampleTime := 0; TempoRefTick := 0; TempoRefSample := 0;
  FillChar(Voices, SizeOf(Voices), 0);
  FillChar(ChProg, SizeOf(ChProg), 0);
  FillChar(ChBank, SizeOf(ChBank), 0);
  FillChar(ChModWheel, SizeOf(ChModWheel), 0);

  for ch := 0 to MAX_MIDI_CH-1 do
  begin
    ChSustain[ch]   := False;
    ChVolume[ch]    := 100;
    ChExpr[ch]      := 127;
    ChPan[ch]       := 64;
    ChPitchBend[ch] := 0;
    ChBendRange[ch] := 2;
  end;
  UpdateSecsPerTick;

  // Pre-calculate total samples for WAV header
  LastTick := 0;
  for i := 0 to EvCount-1 do if Events[i].AbsTick > LastTick then LastTick := Events[i].AbsTick;
  PreRefTick := 0; PreRefSample := 0; PreSPT := SecsPerTick; PreTempo := CurTempo;
  for i := 0 to EvCount-1 do
    if Events[i].MetaTempo > 0 then
    begin
      PreRefSample := PreRefSample + Round((Events[i].AbsTick - PreRefTick) * PreSPT * SAMPLE_RATE);
      PreRefTick := Events[i].AbsTick;
      PreTempo   := Events[i].MetaTempo;
      PreSPT     := (PreTempo / 1000000.0) / PPQ;
    end;
  TotalSamples := PreRefSample + Round((LastTick - PreRefTick) * PreSPT * SAMPLE_RATE) + Round(TAIL_SECS * SAMPLE_RATE);

  WriteWavHeader(OutFile, TotalSamples);

  i := 0;
  while i < EvCount do
  begin
    ES := T2S(Events[i].AbsTick);
    if ES > SampleTime then begin RenderBlock(ES - SampleTime); SampleTime := ES; end;

    if Events[i].MetaTempo > 0 then
    begin
      TempoRefSample := T2S(Events[i].AbsTick);
      TempoRefTick   := Events[i].AbsTick;
      CurTempo       := Events[i].MetaTempo;
      UpdateSecsPerTick;
      Inc(i); Continue;
    end;

    St := Events[i].Status and $F0;
    CC := Events[i].Status and $0F;
    case St of
      $90: if Events[i].Data2 > 0 then DoNoteOn(CC, Events[i].Data1, Events[i].Data2)
           else DoNoteOff(CC, Events[i].Data1);
      $80: DoNoteOff(CC, Events[i].Data1);
      $C0: ChProg[CC] := Events[i].Data1;
      $B0:
        case Events[i].Data1 of
          0:  ChBank[CC] := Events[i].Data2;
          1:  ChModWheel[CC] := Events[i].Data2;
          7:  begin ChVolume[CC] := Events[i].Data2; UpdateChannelGain(CC); end;
          10: begin ChPan[CC]    := Events[i].Data2; UpdateChannelGain(CC); end;
          11: begin ChExpr[CC]   := Events[i].Data2; UpdateChannelGain(CC); end;
          64: begin
                ChSustain[CC] := Events[i].Data2 >= 64;
                if not ChSustain[CC] then
                  for ch := 0 to NVoices-1 do
                    if Voices[ch].Active and (Voices[ch].Ch = CC) and Voices[ch].KeyReleased
                       and (Voices[ch].VolPhase <> epRelease) and (Voices[ch].VolPhase <> epDone) then
                    begin
                      Voices[ch].KeyReleased := False;
                      Voices[ch].VolPhase    := epRelease;
                      Voices[ch].VolRelLevel := Voices[ch].VolLevel;
                      Voices[ch].VolTimer    := 0.0;
                      Voices[ch].ModPhase    := epRelease;
                      Voices[ch].ModRelLevel := Voices[ch].ModLevel;
                      Voices[ch].ModTimer    := 0.0;
                    end;
              end;
          120, 123:
            for ch := 0 to NVoices-1 do
              if Voices[ch].Active and (Voices[ch].Ch = CC) then
              begin
                Voices[ch].VolPhase    := epRelease;
                Voices[ch].VolRelLevel := Voices[ch].VolLevel;
                Voices[ch].VolTimer    := 0.0;
              end;
          // Registered parameter number (RPN) for pitch bend range
          // 100 (RPN LSB), 101 (RPN MSB) — simplified: just track Data2 for CC6
          6:  begin
                // Data entry for RPN - if last RPN was 0,0 (pitch bend range)
                if ChBendRange[CC] >= 0 then ChBendRange[CC] := Events[i].Data2;
              end;
        end;
      $E0:
        begin
          BendVal := (((Integer(Events[i].Data2) shl 7) or Integer(Events[i].Data1)) - 8192);
          ChPitchBend[CC] := BendVal;
          UpdatePitchBend(CC);
        end;
    end;
    Inc(i);
  end;

  // Render tail
  TailRendered := 0; MaxTailSamples := Round(TAIL_SECS * SAMPLE_RATE);
  while TailRendered < MaxTailSamples do
  begin
    AnyActive := False;
    for ch := 0 to NVoices-1 do if Voices[ch].Active then begin AnyActive := True; Break; end;
    if not AnyActive then Break;
    if MaxTailSamples - TailRendered > BUF_FRAMES then
      RenderBlock(BUF_FRAMES)
    else
      RenderBlock(MaxTailSamples - TailRendered);
    Inc(TailRendered, BUF_FRAMES);
  end;
  SampleTime := SampleTime + TailRendered;

  // Rewrite WAV header with actual sample count
  TotalSamples := SampleTime;
  OutFile.Seek(0, soBeginning);
  WriteWavHeader(OutFile, TotalSamples);
  OutFile.Seek(0, soEnd);

  WriteLn(Format('  Rendered %.2f seconds.', [TotalSamples / SAMPLE_RATE]));
end;

// ===========================================================================
//  MAIN
// ===========================================================================
var
  MidiPath, SF2Path, WavPath: string;
  MS, WS: TFileStream;
  SF: TSF2;
  RawSig: array[0..3] of Char;
  Sig: string;
  Fmt, NT, PPQ: Word;
  CLen: TUInt32;
  t: Integer;
  Ev: TMidiEventArray;
  EvN: Integer;
begin
  if ParamCount < 2 then begin WriteLn('Usage: midi2wav <input.mid> <soundfont.sf2> [output.wav]'); Halt(1); end;

  MidiPath := ParamStr(1); SF2Path := ParamStr(2);
  if ParamCount >= 3 then WavPath := ParamStr(3) else WavPath := ChangeFileExt(MidiPath, '.wav');

  if not FileExists(MidiPath) then begin WriteLn('MIDI not found: ', MidiPath); Halt(1); end;
  if not FileExists(SF2Path) then begin WriteLn('SF2 not found: ', SF2Path); Halt(1); end;

  WriteLn('MIDI : ', MidiPath);
  WriteLn('SF2  : ', SF2Path);
  WriteLn('WAV  : ', WavPath);

  SF := TSF2.Create(SF2Path);
  try
    MS := TFileStream.Create(MidiPath, fmOpenRead or fmShareDenyWrite);
    try
      MS.ReadBuffer(RawSig, 4);
      Sig := RawSig[0] + RawSig[1] + RawSig[2] + RawSig[3];
      if Sig <> 'MThd' then begin WriteLn('Not a MIDI file.'); Halt(1); end;
      CLen := ReadBE32(MS);
      Fmt  := ReadBE16(MS);
      NT   := ReadBE16(MS);
      PPQ  := ReadBE16(MS);
      if CLen > 6 then MS.Seek(CLen - 6, soCurrent);
      if PPQ and $8000 <> 0 then begin WriteLn('SMPTE timecode not supported.'); Halt(1); end;
      WriteLn(Format('  Format %d, %d track(s), %d PPQ', [Fmt, NT, PPQ]));

      SetLength(Ev, 4096); EvN := 0;
      for t := 0 to NT-1 do
      begin
        MS.ReadBuffer(RawSig, 4);
        CLen := ReadBE32(MS);
        Sig  := RawSig[0] + RawSig[1] + RawSig[2] + RawSig[3];
        if Sig <> 'MTrk' then begin MS.Seek(CLen, soCurrent); Continue; end;
        ParseTrack(MS, CLen, Ev, EvN);
        WriteLn(Format('  Track %d parsed (%d events total)', [t+1, EvN]));
      end;
      SortEvents(Ev, EvN);
    finally MS.Free; end;

    WriteLn('Synthesizing...');
    WS := TFileStream.Create(WavPath, fmCreate);
    try Synthesize(SF, Ev, EvN, PPQ, WS); finally WS.Free; end;
  finally SF.Free; end;

  WriteLn('Done. WAV written to: ', WavPath);
end.
