const std = @import("std");

const regexp_unicode = @import("../libs/regexp_unicode.zig");
const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const quickjs_regexp = @import("../libs/quickjs_regexp.zig");
const unicode_lib = @import("../libs/unicode.zig");
const emoji = @import("../libs/emoji.zig");
const call_mod = @import("call.zig");
const frame_mod = @import("frame.zig");
const iter_vm = @import("iterator_ops.zig");
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");

const shared_vm = @import("shared.zig");
const RegExpCapture = shared_vm.RegExpCapture;
const SimpleAsciiLiteralClassPlusLiteral = shared_vm.SimpleAsciiLiteralClassPlusLiteral;
const SimpleCaptureSequenceAtom = shared_vm.SimpleCaptureSequenceAtom;
const SimpleCaptureSequencePattern = shared_vm.SimpleCaptureSequencePattern;
const SimpleClassAlternationPattern = shared_vm.SimpleClassAlternationPattern;
const SimpleClassPredicate = shared_vm.SimpleClassPredicate;
const SimpleClassSequenceAtom = shared_vm.SimpleClassSequenceAtom;
const SimpleClassSequencePattern = shared_vm.SimpleClassSequencePattern;
const UnicodePropertyRunPattern = shared_vm.UnicodePropertyRunPattern;
const ValueSliceRoot = shared_vm.ValueSliceRoot;
const anchoredBinaryPropertyName = shared_vm.anchoredBinaryPropertyName;
const appendAsciiUnits = shared_vm.appendAsciiUnits;
const appendBacktraceFunctionName = shared_vm.appendBacktraceFunctionName;
const appendCallSiteFileName = shared_vm.appendCallSiteFileName;
const appendCallSiteFunctionName = shared_vm.appendCallSiteFunctionName;
const appendNamedCaptureSubstitution = shared_vm.appendNamedCaptureSubstitution;
const appendRegExpFlags = shared_vm.appendRegExpFlags;
const appendRegExpSource = shared_vm.appendRegExpSource;
const appendRepeatedFillUnits = shared_vm.appendRepeatedFillUnits;
const arrayFirstIndexStart = shared_vm.arrayFirstIndexStart;
const arrayLastIndexStart = shared_vm.arrayLastIndexStart;
const arrayMethodTypedArrayLength = shared_vm.arrayMethodTypedArrayLength;
const arrayPrototypeFromGlobal = shared_vm.arrayPrototypeFromGlobal;
const arrayPrototypeRecordId = shared_vm.arrayPrototypeRecordId;
const arraySpeciesCreate = shared_vm.arraySpeciesCreate;
const arraySpeciesOriginalIsArray = shared_vm.arraySpeciesOriginalIsArray;
const atomIdOrNameEql = shared_vm.atomIdOrNameEql;
const backtraceFunctionNameEql = shared_vm.backtraceFunctionNameEql;
const bytecodeFunctionObjectTag = shared_vm.bytecodeFunctionObjectTag;
const callObjectToPrimitiveMethod = shared_vm.callObjectToPrimitiveMethod;
const callValueOrBytecode = shared_vm.callValueOrBytecode;
const callableObjectFromValue = shared_vm.callableObjectFromValue;
const classEscapeIsQuantified = shared_vm.classEscapeIsQuantified;
const classEscapeKindIndex = shared_vm.classEscapeKindIndex;
const classEscapeRunLengthLatin1 = shared_vm.classEscapeRunLengthLatin1;
const classEscapeRunLengthUtf16 = shared_vm.classEscapeRunLengthUtf16;
const clearRegExpLegacySlot = shared_vm.clearRegExpLegacySlot;
const constructValueOrBytecode = shared_vm.constructValueOrBytecode;
const constructorPrototypeFromGlobal = shared_vm.constructorPrototypeFromGlobal;
const createDataPropertyOrThrow = shared_vm.createDataPropertyOrThrow;
const createIteratorResult = shared_vm.createIteratorResult;
const createRegExpIndicesArray = shared_vm.createRegExpIndicesArray;
const defineFreshNonIndexDataProperty = shared_vm.defineFreshNonIndexDataProperty;
const defineNativeDataMethod = shared_vm.defineNativeDataMethod;
const defineRegExpGroupsProperty = shared_vm.defineRegExpGroupsProperty;
const defineRegExpGroupsPropertyFromValue = shared_vm.defineRegExpGroupsPropertyFromValue;
const errorStackTraceLimit = shared_vm.errorStackTraceLimit;
const exactScriptExtensionsAliasTarget = shared_vm.exactScriptExtensionsAliasTarget;
const getIteratorMethod = shared_vm.getIteratorMethod;
const getValueProperty = shared_vm.getValueProperty;
const hasValueProperty = shared_vm.hasValueProperty;
const isAdlamScriptExtensionsName = shared_vm.isAdlamScriptExtensionsName;
const isArabicScriptExtensionsName = shared_vm.isArabicScriptExtensionsName;
const isArmenianScriptExtensionsName = shared_vm.isArmenianScriptExtensionsName;
const isArrayPrototypeRecord = shared_vm.isArrayPrototypeRecord;
const isAsciiDigitUnit = shared_vm.isAsciiDigitUnit;
const isAsciiWordUnit = shared_vm.isAsciiWordUnit;
const isAvestanScriptExtensionsName = shared_vm.isAvestanScriptExtensionsName;
const isBengaliScriptExtensionsName = shared_vm.isBengaliScriptExtensionsName;
const isBopomofoScriptExtensionsName = shared_vm.isBopomofoScriptExtensionsName;
const isBugineseScriptExtensionsName = shared_vm.isBugineseScriptExtensionsName;
const isCallableValue = shared_vm.isCallableValue;
const isCarianScriptExtensionsName = shared_vm.isCarianScriptExtensionsName;
const isCaucasianAlbanianScriptExtensionsName = shared_vm.isCaucasianAlbanianScriptExtensionsName;
const isChakmaScriptExtensionsName = shared_vm.isChakmaScriptExtensionsName;
const isCherokeeScriptExtensionsName = shared_vm.isCherokeeScriptExtensionsName;
const isCommonScriptExtensionsName = shared_vm.isCommonScriptExtensionsName;
const isControlGeneralCategoryName = shared_vm.isControlGeneralCategoryName;
const isCopticScriptExtensionsName = shared_vm.isCopticScriptExtensionsName;
const isCopticScriptName = shared_vm.isCopticScriptName;
const isCypriotScriptExtensionsName = shared_vm.isCypriotScriptExtensionsName;
const isCyrillicScriptExtensionsName = shared_vm.isCyrillicScriptExtensionsName;
const isDecimalNumberGeneralCategoryName = shared_vm.isDecimalNumberGeneralCategoryName;
const isDevanagariScriptExtensionsName = shared_vm.isDevanagariScriptExtensionsName;
const isDograScriptExtensionsName = shared_vm.isDograScriptExtensionsName;
const isDuployanScriptExtensionsName = shared_vm.isDuployanScriptExtensionsName;
const isEcmaWhitespaceOrLineTerminator = shared_vm.isEcmaWhitespaceOrLineTerminator;
const isElbasanScriptExtensionsName = shared_vm.isElbasanScriptExtensionsName;
const isEthiopicScriptExtensionsName = shared_vm.isEthiopicScriptExtensionsName;
const isGarayScriptExtensionsName = shared_vm.isGarayScriptExtensionsName;
const isGeorgianScriptExtensionsName = shared_vm.isGeorgianScriptExtensionsName;
const isGlagoliticScriptExtensionsName = shared_vm.isGlagoliticScriptExtensionsName;
const isGothicScriptExtensionsName = shared_vm.isGothicScriptExtensionsName;
const isGranthaScriptExtensionsName = shared_vm.isGranthaScriptExtensionsName;
const isGraphemeBaseName = shared_vm.isGraphemeBaseName;
const isGreekScriptExtensionsName = shared_vm.isGreekScriptExtensionsName;
const isGujaratiScriptExtensionsName = shared_vm.isGujaratiScriptExtensionsName;
const isGunjalaGondiScriptExtensionsName = shared_vm.isGunjalaGondiScriptExtensionsName;
const isGurmukhiScriptExtensionsName = shared_vm.isGurmukhiScriptExtensionsName;
const isHanScriptExtensionsName = shared_vm.isHanScriptExtensionsName;
const isHanScriptName = shared_vm.isHanScriptName;
const isHangulScriptExtensionsName = shared_vm.isHangulScriptExtensionsName;
const isHanifiRohingyaScriptExtensionsName = shared_vm.isHanifiRohingyaScriptExtensionsName;
const isHanunooScriptExtensionsName = shared_vm.isHanunooScriptExtensionsName;
const isHebrewScriptExtensionsName = shared_vm.isHebrewScriptExtensionsName;
const isHighSurrogateUnit = shared_vm.isHighSurrogateUnit;
const isHiraganaScriptExtensionsName = shared_vm.isHiraganaScriptExtensionsName;
const isIdContinueName = shared_vm.isIdContinueName;
const isImperialAramaicScriptExtensionsName = shared_vm.isImperialAramaicScriptExtensionsName;
const isInheritedScriptExtensionsName = shared_vm.isInheritedScriptExtensionsName;
const isInheritedScriptName = shared_vm.isInheritedScriptName;
const isJavaneseScriptExtensionsName = shared_vm.isJavaneseScriptExtensionsName;
const isKaithiScriptExtensionsName = shared_vm.isKaithiScriptExtensionsName;
const isKannadaScriptExtensionsName = shared_vm.isKannadaScriptExtensionsName;
const isKatakanaScriptExtensionsName = shared_vm.isKatakanaScriptExtensionsName;
const isKawiScriptExtensionsName = shared_vm.isKawiScriptExtensionsName;
const isKayahLiScriptExtensionsName = shared_vm.isKayahLiScriptExtensionsName;
const isKhojkiScriptExtensionsName = shared_vm.isKhojkiScriptExtensionsName;
const isKhudawadiScriptExtensionsName = shared_vm.isKhudawadiScriptExtensionsName;
const isKiratRaiScriptName = shared_vm.isKiratRaiScriptName;
const isLaoScriptExtensionsName = shared_vm.isLaoScriptExtensionsName;
const isLatinScriptExtensionsName = shared_vm.isLatinScriptExtensionsName;
const isLetterGeneralCategoryName = shared_vm.isLetterGeneralCategoryName;
const isLimbuScriptExtensionsName = shared_vm.isLimbuScriptExtensionsName;
const isLineTerminatorUnit = shared_vm.isLineTerminatorUnit;
const isLinearAScriptExtensionsName = shared_vm.isLinearAScriptExtensionsName;
const isLinearBScriptExtensionsName = shared_vm.isLinearBScriptExtensionsName;
const isLisuScriptExtensionsName = shared_vm.isLisuScriptExtensionsName;
const isLowSurrogateUnit = shared_vm.isLowSurrogateUnit;
const isLycianScriptExtensionsName = shared_vm.isLycianScriptExtensionsName;
const isLydianScriptExtensionsName = shared_vm.isLydianScriptExtensionsName;
const isMahajaniScriptExtensionsName = shared_vm.isMahajaniScriptExtensionsName;
const isMalayalamScriptExtensionsName = shared_vm.isMalayalamScriptExtensionsName;
const isMandaicScriptExtensionsName = shared_vm.isMandaicScriptExtensionsName;
const isManichaeanScriptExtensionsName = shared_vm.isManichaeanScriptExtensionsName;
const isMarkGeneralCategoryName = shared_vm.isMarkGeneralCategoryName;
const isMasaramGondiScriptExtensionsName = shared_vm.isMasaramGondiScriptExtensionsName;
const isMedefaidrinScriptExtensionsName = shared_vm.isMedefaidrinScriptExtensionsName;
const isMeeteiMayekScriptExtensionsName = shared_vm.isMeeteiMayekScriptExtensionsName;
const isMendeKikakuiScriptExtensionsName = shared_vm.isMendeKikakuiScriptExtensionsName;
const isMeroiticCursiveScriptExtensionsName = shared_vm.isMeroiticCursiveScriptExtensionsName;
const isMeroiticHieroglyphsScriptExtensionsName = shared_vm.isMeroiticHieroglyphsScriptExtensionsName;
const isMiaoScriptExtensionsName = shared_vm.isMiaoScriptExtensionsName;
const isMiaoScriptName = shared_vm.isMiaoScriptName;
const isModiScriptExtensionsName = shared_vm.isModiScriptExtensionsName;
const isMongolianScriptExtensionsName = shared_vm.isMongolianScriptExtensionsName;
const isMroScriptExtensionsName = shared_vm.isMroScriptExtensionsName;
const isMultaniScriptExtensionsName = shared_vm.isMultaniScriptExtensionsName;
const isMyanmarScriptExtensionsName = shared_vm.isMyanmarScriptExtensionsName;
const isNabataeanScriptExtensionsName = shared_vm.isNabataeanScriptExtensionsName;
const isNagMundariScriptExtensionsName = shared_vm.isNagMundariScriptExtensionsName;
const isNandinagariScriptExtensionsName = shared_vm.isNandinagariScriptExtensionsName;
const isNandinagariScriptName = shared_vm.isNandinagariScriptName;
const isNewTaiLueScriptExtensionsName = shared_vm.isNewTaiLueScriptExtensionsName;
const isNewTaiLueScriptName = shared_vm.isNewTaiLueScriptName;
const isNewaScriptExtensionsName = shared_vm.isNewaScriptExtensionsName;
const isNewaScriptName = shared_vm.isNewaScriptName;
const isNkoScriptExtensionsName = shared_vm.isNkoScriptExtensionsName;
const isNkoScriptName = shared_vm.isNkoScriptName;
const isNumberCategoryName = shared_vm.isNumberCategoryName;
const isNushuScriptExtensionsName = shared_vm.isNushuScriptExtensionsName;
const isNushuScriptName = shared_vm.isNushuScriptName;
const isNyiakengPuachueHmongScriptExtensionsName = shared_vm.isNyiakengPuachueHmongScriptExtensionsName;
const isNyiakengPuachueHmongScriptName = shared_vm.isNyiakengPuachueHmongScriptName;
const isOghamScriptExtensionsName = shared_vm.isOghamScriptExtensionsName;
const isOghamScriptName = shared_vm.isOghamScriptName;
const isOlChikiScriptExtensionsName = shared_vm.isOlChikiScriptExtensionsName;
const isOlChikiScriptName = shared_vm.isOlChikiScriptName;
const isOlOnalScriptExtensionsName = shared_vm.isOlOnalScriptExtensionsName;
const isOlOnalScriptName = shared_vm.isOlOnalScriptName;
const isOldHungarianScriptExtensionsName = shared_vm.isOldHungarianScriptExtensionsName;
const isOldHungarianScriptName = shared_vm.isOldHungarianScriptName;
const isOldItalicScriptExtensionsName = shared_vm.isOldItalicScriptExtensionsName;
const isOldItalicScriptName = shared_vm.isOldItalicScriptName;
const isOldNorthArabianScriptExtensionsName = shared_vm.isOldNorthArabianScriptExtensionsName;
const isOldNorthArabianScriptName = shared_vm.isOldNorthArabianScriptName;
const isOldPermicScriptExtensionsName = shared_vm.isOldPermicScriptExtensionsName;
const isOldPermicScriptName = shared_vm.isOldPermicScriptName;
const isOldPersianScriptExtensionsName = shared_vm.isOldPersianScriptExtensionsName;
const isOldPersianScriptName = shared_vm.isOldPersianScriptName;
const isOldSogdianScriptExtensionsName = shared_vm.isOldSogdianScriptExtensionsName;
const isOldSogdianScriptName = shared_vm.isOldSogdianScriptName;
const isOldSouthArabianScriptExtensionsName = shared_vm.isOldSouthArabianScriptExtensionsName;
const isOldSouthArabianScriptName = shared_vm.isOldSouthArabianScriptName;
const isOldTurkicScriptExtensionsName = shared_vm.isOldTurkicScriptExtensionsName;
const isOldTurkicScriptName = shared_vm.isOldTurkicScriptName;
const isOldUyghurScriptExtensionsName = shared_vm.isOldUyghurScriptExtensionsName;
const isOldUyghurScriptName = shared_vm.isOldUyghurScriptName;
const isOriyaScriptExtensionsName = shared_vm.isOriyaScriptExtensionsName;
const isOriyaScriptName = shared_vm.isOriyaScriptName;
const isOsageScriptExtensionsName = shared_vm.isOsageScriptExtensionsName;
const isOsageScriptName = shared_vm.isOsageScriptName;
const isOsmanyaScriptExtensionsName = shared_vm.isOsmanyaScriptExtensionsName;
const isOsmanyaScriptName = shared_vm.isOsmanyaScriptName;
const isOtherGeneralCategoryName = shared_vm.isOtherGeneralCategoryName;
const isOtherLetterGeneralCategoryName = shared_vm.isOtherLetterGeneralCategoryName;
const isPahawhHmongScriptExtensionsName = shared_vm.isPahawhHmongScriptExtensionsName;
const isPahawhHmongScriptName = shared_vm.isPahawhHmongScriptName;
const isPalmyreneScriptExtensionsName = shared_vm.isPalmyreneScriptExtensionsName;
const isPalmyreneScriptName = shared_vm.isPalmyreneScriptName;
const isPauCinHauScriptExtensionsName = shared_vm.isPauCinHauScriptExtensionsName;
const isPauCinHauScriptName = shared_vm.isPauCinHauScriptName;
const isPhagsPaScriptExtensionsName = shared_vm.isPhagsPaScriptExtensionsName;
const isPhagsPaScriptName = shared_vm.isPhagsPaScriptName;
const isPhoenicianScriptExtensionsName = shared_vm.isPhoenicianScriptExtensionsName;
const isPhoenicianScriptName = shared_vm.isPhoenicianScriptName;
const isPlainAsciiRegExpLiteral = shared_vm.isPlainAsciiRegExpLiteral;
const isPsalterPahlaviScriptExtensionsName = shared_vm.isPsalterPahlaviScriptExtensionsName;
const isPsalterPahlaviScriptName = shared_vm.isPsalterPahlaviScriptName;
const isPunctuationGeneralCategoryName = shared_vm.isPunctuationGeneralCategoryName;
const isRegExpLineTerminator = shared_vm.isRegExpLineTerminator;
const isRegExpObservable = shared_vm.isRegExpObservable;
const isRejangScriptExtensionsName = shared_vm.isRejangScriptExtensionsName;
const isRejangScriptName = shared_vm.isRejangScriptName;
const isRunicScriptExtensionsName = shared_vm.isRunicScriptExtensionsName;
const isRunicScriptName = shared_vm.isRunicScriptName;
const isSamaritanScriptExtensionsName = shared_vm.isSamaritanScriptExtensionsName;
const isSamaritanScriptName = shared_vm.isSamaritanScriptName;
const isSaurashtraScriptExtensionsName = shared_vm.isSaurashtraScriptExtensionsName;
const isSaurashtraScriptName = shared_vm.isSaurashtraScriptName;
const isSharadaScriptExtensionsName = shared_vm.isSharadaScriptExtensionsName;
const isSharadaScriptName = shared_vm.isSharadaScriptName;
const isShavianScriptExtensionsName = shared_vm.isShavianScriptExtensionsName;
const isShavianScriptName = shared_vm.isShavianScriptName;
const isSiddhamScriptExtensionsName = shared_vm.isSiddhamScriptExtensionsName;
const isSiddhamScriptName = shared_vm.isSiddhamScriptName;
const isSideticScriptExtensionsName = shared_vm.isSideticScriptExtensionsName;
const isSideticScriptName = shared_vm.isSideticScriptName;
const isSignWritingScriptExtensionsName = shared_vm.isSignWritingScriptExtensionsName;
const isSignWritingScriptName = shared_vm.isSignWritingScriptName;
const isSinhalaScriptExtensionsName = shared_vm.isSinhalaScriptExtensionsName;
const isSinhalaScriptName = shared_vm.isSinhalaScriptName;
const isSogdianScriptExtensionsName = shared_vm.isSogdianScriptExtensionsName;
const isSogdianScriptName = shared_vm.isSogdianScriptName;
const isSoraSompengScriptExtensionsName = shared_vm.isSoraSompengScriptExtensionsName;
const isSoraSompengScriptName = shared_vm.isSoraSompengScriptName;
const isSoyomboScriptExtensionsName = shared_vm.isSoyomboScriptExtensionsName;
const isSoyomboScriptName = shared_vm.isSoyomboScriptName;
const isSundaneseScriptExtensionsName = shared_vm.isSundaneseScriptExtensionsName;
const isSundaneseScriptName = shared_vm.isSundaneseScriptName;
const isSunuwarScriptExtensionsName = shared_vm.isSunuwarScriptExtensionsName;
const isSunuwarScriptName = shared_vm.isSunuwarScriptName;
const isSylotiNagriScriptExtensionsName = shared_vm.isSylotiNagriScriptExtensionsName;
const isSylotiNagriScriptName = shared_vm.isSylotiNagriScriptName;
const isSymbolGeneralCategoryName = shared_vm.isSymbolGeneralCategoryName;
const isSyriacScriptExtensionsName = shared_vm.isSyriacScriptExtensionsName;
const isSyriacScriptName = shared_vm.isSyriacScriptName;
const isTagalogScriptExtensionsName = shared_vm.isTagalogScriptExtensionsName;
const isTagalogScriptName = shared_vm.isTagalogScriptName;
const isTagbanwaScriptExtensionsName = shared_vm.isTagbanwaScriptExtensionsName;
const isTagbanwaScriptName = shared_vm.isTagbanwaScriptName;
const isTaiLeScriptExtensionsName = shared_vm.isTaiLeScriptExtensionsName;
const isTaiLeScriptName = shared_vm.isTaiLeScriptName;
const isTaiThamScriptExtensionsName = shared_vm.isTaiThamScriptExtensionsName;
const isTaiThamScriptName = shared_vm.isTaiThamScriptName;
const isTaiVietScriptExtensionsName = shared_vm.isTaiVietScriptExtensionsName;
const isTaiVietScriptName = shared_vm.isTaiVietScriptName;
const isTaiYoScriptExtensionsName = shared_vm.isTaiYoScriptExtensionsName;
const isTaiYoScriptName = shared_vm.isTaiYoScriptName;
const isTakriScriptExtensionsName = shared_vm.isTakriScriptExtensionsName;
const isTakriScriptName = shared_vm.isTakriScriptName;
const isTamilScriptExtensionsName = shared_vm.isTamilScriptExtensionsName;
const isTamilScriptName = shared_vm.isTamilScriptName;
const isTangsaScriptExtensionsName = shared_vm.isTangsaScriptExtensionsName;
const isTangsaScriptName = shared_vm.isTangsaScriptName;
const isTangutScriptExtensionsName = shared_vm.isTangutScriptExtensionsName;
const isTangutScriptName = shared_vm.isTangutScriptName;
const isTeluguScriptExtensionsName = shared_vm.isTeluguScriptExtensionsName;
const isTeluguScriptName = shared_vm.isTeluguScriptName;
const isThaanaScriptExtensionsName = shared_vm.isThaanaScriptExtensionsName;
const isThaanaScriptName = shared_vm.isThaanaScriptName;
const isThaiScriptExtensionsName = shared_vm.isThaiScriptExtensionsName;
const isThaiScriptName = shared_vm.isThaiScriptName;
const isTibetanScriptExtensionsName = shared_vm.isTibetanScriptExtensionsName;
const isTibetanScriptName = shared_vm.isTibetanScriptName;
const isTifinaghScriptExtensionsName = shared_vm.isTifinaghScriptExtensionsName;
const isTifinaghScriptName = shared_vm.isTifinaghScriptName;
const isTirhutaScriptExtensionsName = shared_vm.isTirhutaScriptExtensionsName;
const isTirhutaScriptName = shared_vm.isTirhutaScriptName;
const isTodhriScriptExtensionsName = shared_vm.isTodhriScriptExtensionsName;
const isTodhriScriptName = shared_vm.isTodhriScriptName;
const isTolongSikiScriptExtensionsName = shared_vm.isTolongSikiScriptExtensionsName;
const isTolongSikiScriptName = shared_vm.isTolongSikiScriptName;
const isTotoScriptExtensionsName = shared_vm.isTotoScriptExtensionsName;
const isTotoScriptName = shared_vm.isTotoScriptName;
const isTuluTigalariScriptExtensionsName = shared_vm.isTuluTigalariScriptExtensionsName;
const isTuluTigalariScriptName = shared_vm.isTuluTigalariScriptName;
const isTypedArrayPrototypeMethod = shared_vm.isTypedArrayPrototypeMethod;
const isUgariticScriptExtensionsName = shared_vm.isUgariticScriptExtensionsName;
const isUgariticScriptName = shared_vm.isUgariticScriptName;
const isUnassignedGeneralCategoryName = shared_vm.isUnassignedGeneralCategoryName;
const isUnknownScriptName = shared_vm.isUnknownScriptName;
const isUppercaseLetterGeneralCategoryName = shared_vm.isUppercaseLetterGeneralCategoryName;
const isVaiScriptExtensionsName = shared_vm.isVaiScriptExtensionsName;
const isVaiScriptName = shared_vm.isVaiScriptName;
const isVithkuqiScriptExtensionsName = shared_vm.isVithkuqiScriptExtensionsName;
const isVithkuqiScriptName = shared_vm.isVithkuqiScriptName;
const isWanchoScriptExtensionsName = shared_vm.isWanchoScriptExtensionsName;
const isWanchoScriptName = shared_vm.isWanchoScriptName;
const isWarangCitiScriptExtensionsName = shared_vm.isWarangCitiScriptExtensionsName;
const isWarangCitiScriptName = shared_vm.isWarangCitiScriptName;
const isXidContinueName = shared_vm.isXidContinueName;
const isYezidiScriptExtensionsName = shared_vm.isYezidiScriptExtensionsName;
const isYezidiScriptName = shared_vm.isYezidiScriptName;
const isYiScriptExtensionsName = shared_vm.isYiScriptExtensionsName;
const isYiScriptName = shared_vm.isYiScriptName;
const isZanabazarSquareScriptExtensionsName = shared_vm.isZanabazarSquareScriptExtensionsName;
const isZanabazarSquareScriptName = shared_vm.isZanabazarSquareScriptName;
const leadingAlternationCharacterClassSource = shared_vm.leadingAlternationCharacterClassSource;
const lengthIndexValue = shared_vm.lengthIndexValue;
const lowSurrogateLiteralAt = shared_vm.lowSurrogateLiteralAt;
const normalizedUtf32 = shared_vm.normalizedUtf32;
const objectFromValue = shared_vm.objectFromValue;
const ownDataOrAutoInitPropertyValue = shared_vm.ownDataOrAutoInitPropertyValue;
const parseSimpleClassSequenceSource = shared_vm.parseSimpleClassSequenceSource;
const parseSimpleUnicodeLiteralSource = shared_vm.parseSimpleUnicodeLiteralSource;
const parseSurrogatePairClassSource = shared_vm.parseSurrogatePairClassSource;
const parseUnicodeAstralSpecialSource = shared_vm.parseUnicodeAstralSpecialSource;
const primitiveObjectForAccess = shared_vm.primitiveObjectForAccess;
const propertyAtomFromLengthIndex = shared_vm.propertyAtomFromLengthIndex;
const propertyEscapePattern = shared_vm.propertyEscapePattern;
const proxyTargetIsCallableObject = shared_vm.proxyTargetIsCallableObject;
const qjsArrayLastIndexSparseLarge = shared_vm.qjsArrayLastIndexSparseLarge;
const qjsIteratorPrototype = shared_vm.qjsIteratorPrototype;
const qjsRegExpConstructCall = shared_vm.qjsRegExpConstructCall;
const qjsRegExpExecGeneric = shared_vm.qjsRegExpExecGeneric;
const qjsRegExpExecSimpleUnicodeLiteral = shared_vm.qjsRegExpExecSimpleUnicodeLiteral;
const qjsRegExpSpeciesConstructor = shared_vm.qjsRegExpSpeciesConstructor;
const readUnicodePropertyClassEscape = shared_vm.readUnicodePropertyClassEscape;
const regExpConstructorFromGlobal = shared_vm.regExpConstructorFromGlobal;
const regExpExecPropertyIsDefault = shared_vm.regExpExecPropertyIsDefault;
const regExpFlagsAreFullUnicode = shared_vm.regExpFlagsAreFullUnicode;
const regexpBorrowedLatin1SourceFlags = shared_vm.regexpBorrowedLatin1SourceFlags;
const regexpInternalFlagsContain = shared_vm.regexpInternalFlagsContain;
const regexpInternalSimpleQuantifiedClassSource = shared_vm.regexpInternalSimpleQuantifiedClassSource;
const regexpSimpleCaptureSequencePattern = shared_vm.regexpSimpleCaptureSequencePattern;
const setRegExpLastIndexZero = shared_vm.setRegExpLastIndexZero;
const setValueProperty = shared_vm.setValueProperty;
const setValuePropertyStrict = shared_vm.setValuePropertyStrict;
const simpleCaptureSequenceAtLatin1 = shared_vm.simpleCaptureSequenceAtLatin1;
const simpleCaptureSequenceAtUtf16 = shared_vm.simpleCaptureSequenceAtUtf16;
const simpleClassSequenceAtLatin1 = shared_vm.simpleClassSequenceAtLatin1;
const simpleClassSequenceAtUtf16 = shared_vm.simpleClassSequenceAtUtf16;
const simpleUnicodeLiteralAt = shared_vm.simpleUnicodeLiteralAt;
const singleLowSurrogateLiteralSource = shared_vm.singleLowSurrogateLiteralSource;
const standaloneCharacterClassSource = shared_vm.standaloneCharacterClassSource;
const surrogatePairClassAt = shared_vm.surrogatePairClassAt;

const throwRangeErrorMessage = shared_vm.throwRangeErrorMessage;
const throwTypeErrorMessage = shared_vm.throwTypeErrorMessage;
const toLengthIndex = shared_vm.toLengthIndex;
const toLengthNumber = shared_vm.toLengthNumber;
const toNumberLikeArgument = shared_vm.toNumberLikeArgument;
const toPrimitiveForNumber = shared_vm.toPrimitiveForNumber;
const toUint16CodeUnit = shared_vm.toUint16CodeUnit;
const toUint32Number = shared_vm.toUint32Number;
const uint32NumberValue = shared_vm.uint32NumberValue;
const unicodeAstralSpecialAt = shared_vm.unicodeAstralSpecialAt;
const unicodePropertyOnlyClassBody = shared_vm.unicodePropertyOnlyClassBody;
const unicodePropertyOnlyClassSource = shared_vm.unicodePropertyOnlyClassSource;
const updateRegExpLegacyStaticsNoCaptures = shared_vm.updateRegExpLegacyStaticsNoCaptures;
const valueTruthy = shared_vm.valueTruthy;
const valuesStrictEqual = shared_vm.valuesStrictEqual;

pub fn toStringForAnnexB(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (value.isSymbol()) return error.TypeError;
    if (value.isString()) return value.dup();
    const primitive = if (value.isObject())
        try toPrimitiveForString(ctx, output, global, value, caller_function, caller_frame)
    else
        value.dup();
    defer primitive.free(ctx.runtime);
    if (primitive.isSymbol()) return error.TypeError;
    if (primitive.isString()) return primitive.dup();
    return value_ops.toStringValue(ctx.runtime, primitive);
}

pub fn toPrimitiveForString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!value.isObject()) return value.dup();
    const symbol_to_primitive = core.atom.predefinedId("Symbol.toPrimitive", .symbol) orelse
        return toOrdinaryPrimitiveString(ctx, output, global, value, caller_function, caller_frame);
    const method = try getValueProperty(ctx, output, global, value, symbol_to_primitive, caller_function, caller_frame);
    defer method.free(ctx.runtime);
    if (!method.isUndefined() and !method.isNull()) {
        if (!isCallableValue(method)) return error.TypeError;
        const hint = try value_ops.createStringValue(ctx.runtime, "string");
        defer hint.free(ctx.runtime);
        const primitive = try callValueOrBytecode(ctx, output, global, value, method, &.{hint}, caller_function, caller_frame);
        if (primitive.isObject()) {
            primitive.free(ctx.runtime);
            return error.TypeError;
        }
        return primitive;
    }
    return toOrdinaryPrimitiveString(ctx, output, global, value, caller_function, caller_frame);
}

pub fn toOrdinaryPrimitiveString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, "toString", caller_function, caller_frame)) |primitive| return primitive;
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, "valueOf", caller_function, caller_frame)) |primitive| return primitive;
    return error.TypeError;
}

pub fn qjsStringFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len == 0) return value_ops.createStringValue(ctx.runtime, "");
    if (args[0].isSymbol()) return value_ops.toStringValue(ctx.runtime, args[0]);
    if (!args[0].isObject()) return value_ops.toStringValue(ctx.runtime, args[0]);
    return toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
}

pub fn qjsStringConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const string_value = if (args.len == 0)
        try value_ops.createStringValue(ctx.runtime, "")
    else
        try toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    return builtins.string.constructWithPrototype(ctx.runtime, &.{string_value}, prototype);
}

pub fn qjsStringConcat(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) {
        return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);

    const receiver_string = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer receiver_string.free(ctx.runtime);
    try value_ops.appendRawString(ctx.runtime, &bytes, receiver_string);

    for (args) |arg| {
        const arg_string = try toStringForAnnexB(ctx, output, global, arg, caller_function, caller_frame);
        defer arg_string.free(ctx.runtime);
        try value_ops.appendRawString(ctx.runtime, &bytes, arg_string);
    }

    return value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub fn qjsStringReplace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) {
        return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    }
    const search_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const replacement_input = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (try qjsStringReplaceFastRegExp(ctx, output, global, this_value, search_input, replacement_input, caller_function, caller_frame)) |value| return value;
    if (try callStringReplaceMethod(ctx, output, global, this_value, search_input, replacement_input, caller_function, caller_frame)) |value| return value;

    const source_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer source_value.free(ctx.runtime);
    const search_value = try toStringForAnnexB(ctx, output, global, search_input, caller_function, caller_frame);
    defer search_value.free(ctx.runtime);

    var source_units = std.ArrayList(u16).empty;
    defer source_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &source_units, source_value);

    var search_units = std.ArrayList(u16).empty;
    defer search_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &search_units, search_value);

    const functional_replace = isCallableValue(replacement_input);
    const replacement_text = if (functional_replace)
        core.JSValue.undefinedValue()
    else
        try toStringForAnnexB(ctx, output, global, replacement_input, caller_function, caller_frame);
    defer if (!functional_replace) replacement_text.free(ctx.runtime);

    const match_index = std.mem.indexOf(u16, source_units.items, search_units.items) orelse
        return source_value.dup();
    const replacement_value = if (functional_replace) blk: {
        break :blk try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), replacement_input, &.{ search_value, core.JSValue.int32(@intCast(match_index)), source_value }, caller_function, caller_frame);
    } else replacement_text;
    defer if (functional_replace) replacement_value.free(ctx.runtime);

    const replacement_string = try toStringForAnnexB(ctx, output, global, replacement_value, caller_function, caller_frame);
    defer replacement_string.free(ctx.runtime);

    const replacement = if (functional_replace) replacement_string else blk: {
        const match = ReplaceMatch{
            .result = core.JSValue.undefinedValue(),
            .matched = search_value,
            .index = match_index,
            .captures = &.{},
            .groups = core.JSValue.undefinedValue(),
        };
        break :blk try getSubstitutionString(ctx, output, global, match, source_value, replacement_string, caller_function, caller_frame);
    };
    defer if (!functional_replace) replacement.free(ctx.runtime);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[0..match_index]);
    try appendStringValueUnits(ctx.runtime, &out, replacement);
    try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[match_index + search_units.items.len ..]);
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn qjsStringReplaceFastRegExp(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    search_value: core.JSValue,
    replace_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (isCallableValue(replace_value)) return null;
    const regexp_object = objectFromValue(search_value) orelse return null;
    if (regexp_object.class_id != core.class.ids.regexp) return null;
    const replace_atom = core.atom.predefinedId("Symbol.replace", .symbol) orelse return null;
    if (regexp_object.hasOwnProperty(replace_atom)) return null;

    if (regexpInternalFlagsContain(regexp_object, 'g')) {
        if (regexpInternalSimpleQuantifiedClassSource(regexp_object)) |fast_source| {
            try setRegExpLastIndexZero(ctx.runtime, regexp_object);
            const string_value = if (this_value.isString())
                this_value.dup()
            else
                try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
            defer string_value.free(ctx.runtime);
            const replacement_string = if (replace_value.isString())
                replace_value.dup()
            else
                try toStringForAnnexB(ctx, output, global, replace_value, caller_function, caller_frame);
            defer replacement_string.free(ctx.runtime);
            if (replaceSingleUnitGlobalSimpleClassEscape(string_value, replacement_string, fast_source)) |fast| return fast;
            return try replaceGlobalSimpleClassEscape(ctx.runtime, string_value, replacement_string, fast_source);
        }
    }

    var flags = std.ArrayList(u8).empty;
    defer flags.deinit(ctx.runtime.memory.allocator);
    if (!try appendRegExpFlags(ctx.runtime, regexp_object, &flags)) return null;
    if (std.mem.indexOfScalar(u8, flags.items, 'g') == null) return null;

    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    if (!try appendRegExpSource(ctx.runtime, regexp_object, &source)) return null;
    if (!classEscapeIsQuantified(source.items) or !isSimpleStringClassEscapeSource(source.items)) return null;

    try setRegExpLastIndexZero(ctx.runtime, regexp_object);
    const string_value = if (this_value.isString())
        this_value.dup()
    else
        try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    const replacement_string = if (replace_value.isString())
        replace_value.dup()
    else
        try toStringForAnnexB(ctx, output, global, replace_value, caller_function, caller_frame);
    defer replacement_string.free(ctx.runtime);
    if (replaceSingleUnitGlobalSimpleClassEscape(string_value, replacement_string, source.items)) |fast| return fast;
    return try replaceGlobalSimpleClassEscape(ctx.runtime, string_value, replacement_string, source.items);
}

pub fn callStringReplaceMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    search_value: core.JSValue,
    replace_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!search_value.isObject()) return null;
    const replace_atom = core.atom.predefinedId("Symbol.replace", .symbol) orelse return error.TypeError;
    const replacer = try getValueProperty(ctx, output, global, search_value, replace_atom, caller_function, caller_frame);
    defer replacer.free(ctx.runtime);
    if (replacer.isUndefined() or replacer.isNull()) return null;
    if (!isCallableValue(replacer)) return error.TypeError;
    const replace_args = [_]core.JSValue{ this_value, replace_value };
    return try callValueOrBytecode(ctx, output, global, search_value, replacer, &replace_args, caller_function, caller_frame);
}

pub fn callSimpleStringBytecode(
    rt: *core.JSRuntime,
    fb: *const bytecode.FunctionBytecode,
    args: []const core.JSValue,
) !?core.JSValue {
    switch (fb.simple_string_kind) {
        .percent_hex_byte => {
            if (args.len == 0) return null;
            const byte_i32 = args[0].asInt32() orelse return null;
            const byte: u8 = @truncate(@as(u32, @bitCast(byte_i32)));
            const cached = try rt.percentHexString(byte);
            return cached.value().dup();
        },
        .none => {},
    }
    return null;
}

pub fn buildErrorStackStringValue(ctx: *core.JSContext, global: *core.Object, skip_name: ?[]const u8) !core.JSValue {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);

    const limit = errorStackTraceLimit(ctx.runtime, global);
    if (limit == 0) return value_ops.createStringValue(ctx.runtime, "");

    var idx = ctx.backtrace_frames.len;
    var emitted: usize = 0;
    var skipping = skip_name != null;
    while (idx > 0) {
        idx -= 1;
        if (skipping) {
            if (backtraceFunctionNameEql(ctx, ctx.backtrace_frames[idx], skip_name.?)) skipping = false;
            continue;
        }
        if (emitted >= limit) break;
        const entry = ctx.backtrace_frames[idx];
        if (bytes.items.len != 0) try bytes.append(ctx.runtime.memory.allocator, '\n');
        try bytes.appendSlice(ctx.runtime.memory.allocator, "    at ");
        try appendBacktraceFunctionName(ctx, &bytes, entry.function_name, entry.filename);
        const filename = ctx.runtime.atoms.name(entry.filename) orelse "<anonymous>";
        const location = entry.location();
        const line_num = if (location.line_num > 0) location.line_num else 1;
        const col_num = if (location.col_num > 0) location.col_num else 1;
        const suffix = try std.fmt.allocPrint(ctx.runtime.memory.allocator, " ({s}:{}:{})", .{ filename, line_num, col_num });
        defer ctx.runtime.memory.allocator.free(suffix);
        try bytes.appendSlice(ctx.runtime.memory.allocator, suffix);
        emitted += 1;
    }
    if (emitted != 0) try bytes.append(ctx.runtime.memory.allocator, '\n');

    return value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub fn formatCapturedErrorStackStringValue(ctx: *core.JSContext, sites_value: core.JSValue, site_count: usize) !core.JSValue {
    const sites = objectFromValue(sites_value) orelse return value_ops.createStringValue(ctx.runtime, "");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);

    const current_length: usize = if (sites.is_array) @intCast(sites.length) else 0;
    const length = @min(current_length, site_count);
    var index: usize = 0;
    var emitted: usize = 0;
    while (index < length) : (index += 1) {
        if (index > std.math.maxInt(u32)) break;
        const site_value = sites.getProperty(core.atom.atomFromUInt32(@intCast(index)));
        defer site_value.free(ctx.runtime);
        const site = objectFromValue(site_value) orelse continue;
        if (!site.isCallSite()) continue;
        if (bytes.items.len != 0) try bytes.append(ctx.runtime.memory.allocator, '\n');
        try bytes.appendSlice(ctx.runtime.memory.allocator, "    at ");
        try appendCallSiteFunctionName(ctx.runtime, &bytes, site);

        var filename_bytes: std.ArrayList(u8) = .empty;
        defer filename_bytes.deinit(ctx.runtime.memory.allocator);
        try appendCallSiteFileName(ctx.runtime, &filename_bytes, site);
        const suffix = try std.fmt.allocPrint(
            ctx.runtime.memory.allocator,
            " ({s}:{}:{})",
            .{ filename_bytes.items, site.callSiteLine(), site.callSiteColumn() },
        );
        defer ctx.runtime.memory.allocator.free(suffix);
        try bytes.appendSlice(ctx.runtime.memory.allocator, suffix);
        emitted += 1;
    }
    if (emitted != 0) try bytes.append(ctx.runtime.memory.allocator, '\n');
    return value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub fn qjsStringFromCodePoint(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(ctx.runtime.memory.allocator);
    for (args) |value| {
        const primitive = try toPrimitiveForNumber(ctx, output, global, value);
        defer primitive.free(ctx.runtime);
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        defer number_value.free(ctx.runtime);
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        if (std.math.isNan(number) or !std.math.isFinite(number) or number < 0 or number > 0x10ffff or @trunc(number) != number) {
            return error.RangeError;
        }
        const code_point: u32 = @intFromFloat(number);
        if (code_point <= 0xffff) {
            try units.append(ctx.runtime.memory.allocator, @intCast(code_point));
        } else {
            const adjusted = code_point - 0x10000;
            try units.append(ctx.runtime.memory.allocator, @intCast(0xd800 + (adjusted >> 10)));
            try units.append(ctx.runtime.memory.allocator, @intCast(0xdc00 + (adjusted & 0x3ff)));
        }
    }
    return (try core.string.String.createUtf16(ctx.runtime, units.items)).value();
}

pub fn qjsStringRaw(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const template_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const cooked = try toObjectForStringRaw(ctx, global, template_value);
    defer cooked.free(ctx.runtime);

    const raw_atom = try ctx.runtime.internAtom("raw");
    defer ctx.runtime.atoms.free(raw_atom);
    const raw_candidate = try getValueProperty(ctx, output, global, cooked, raw_atom, caller_function, caller_frame);
    defer raw_candidate.free(ctx.runtime);
    const raw = try toObjectForStringRaw(ctx, global, raw_candidate);
    defer raw.free(ctx.runtime);

    const length_value = try getValueProperty(ctx, output, global, raw, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try toLengthIndex(ctx, output, global, length_value);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);

    var index: usize = 0;
    while (index < length) : (index += 1) {
        if (index > std.math.maxInt(u32)) return error.RangeError;
        const raw_part = try getValueProperty(ctx, output, global, raw, core.atom.atomFromUInt32(@intCast(index)), caller_function, caller_frame);
        defer raw_part.free(ctx.runtime);
        const raw_string = try toStringForAnnexB(ctx, output, global, raw_part, caller_function, caller_frame);
        defer raw_string.free(ctx.runtime);
        try appendStringValueUnits(ctx.runtime, &out, raw_string);

        if (index + 1 < length and index + 1 < args.len) {
            const substitution = try toStringForAnnexB(ctx, output, global, args[index + 1], caller_function, caller_frame);
            defer substitution.free(ctx.runtime);
            try appendStringValueUnits(ctx.runtime, &out, substitution);
        }
    }

    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn toObjectForStringRaw(ctx: *core.JSContext, global: *core.Object, value: core.JSValue) !core.JSValue {
    if (value.isNull() or value.isUndefined()) return error.TypeError;
    if (objectFromValue(value)) |_| return value.dup();
    return primitiveObjectForAccess(ctx.runtime, global, value);
}

pub fn qjsStringFromCodePointArray(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    array_value: core.JSValue,
) !core.JSValue {
    const array = try property_ops.expectObject(array_value);
    if (!array.is_array) return error.TypeError;
    if (try qjsStringFromCodePointDenseArray(ctx.runtime, array)) |value| return value;
    var units = std.ArrayList(u16).empty;
    defer units.deinit(ctx.runtime.memory.allocator);
    var index: u32 = 0;
    while (index < array.length) : (index += 1) {
        const value = array.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(ctx.runtime);
        const primitive = try toPrimitiveForNumber(ctx, output, global, value);
        defer primitive.free(ctx.runtime);
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        defer number_value.free(ctx.runtime);
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        if (std.math.isNan(number) or !std.math.isFinite(number) or number < 0 or number > 0x10ffff or @trunc(number) != number) {
            return error.RangeError;
        }
        const code_point: u32 = @intFromFloat(number);
        if (code_point <= 0xffff) {
            try units.append(ctx.runtime.memory.allocator, @intCast(code_point));
        } else {
            const adjusted = code_point - 0x10000;
            try units.append(ctx.runtime.memory.allocator, @intCast(0xd800 + (adjusted >> 10)));
            try units.append(ctx.runtime.memory.allocator, @intCast(0xdc00 + (adjusted & 0x3ff)));
        }
    }
    return (try core.string.String.createUtf16(ctx.runtime, units.items)).value();
}

pub fn qjsStringFromCodePointDenseArray(rt: *core.JSRuntime, array: *core.Object) !?core.JSValue {
    if (array.arrayElementStorageMode() != .dense) return null;
    const length: usize = @intCast(array.length);
    if (array.arrayElements().len >= length) {
        if (length == 0) return (try core.string.String.createAscii(rt, "")).value();
        const max_units = try std.math.mul(usize, length, 2);
        const units = try rt.memory.alloc(u16, max_units);
        var consumed_units = false;
        defer if (!consumed_units) rt.memory.free(u16, units);

        var unit_count: usize = 0;
        var index: usize = 0;
        while (index < length) : (index += 1) {
            const value = array.arrayElements()[index] orelse return null;
            const number = value_ops.numberValue(value) orelse return null;
            const code_point = validStringCodePoint(number) orelse return error.RangeError;
            if (code_point <= 0xffff) {
                units[unit_count] = @intCast(code_point);
                unit_count += 1;
            } else {
                const adjusted = code_point - 0x10000;
                units[unit_count] = @intCast(0xd800 + (adjusted >> 10));
                units[unit_count + 1] = @intCast(0xdc00 + (adjusted & 0x3ff));
                unit_count += 2;
            }
        }
        const string = try core.string.String.createUtf16Owned(rt, units[0..unit_count], max_units);
        consumed_units = true;
        return string.value();
    }

    var code_points = try rt.memory.alloc(?u32, length);
    defer rt.memory.free(?u32, code_points);
    @memset(code_points, null);

    var seen: usize = 0;
    for (array.properties) |entry| {
        if (entry.flags.deleted) continue;
        const index = core.array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) orelse continue;
        if (index >= array.length) continue;
        if (entry.flags.accessor) return null;
        const value = switch (entry.slot) {
            .data => |stored| stored,
            // Array elements never carry `auto_init` placeholders --
            // those only appear for builtin method tables installed via
            // `defineAutoInitProperty` -- but the switch must be
            // exhaustive after the auto-init slot variant was added.
            .accessor, .auto_init, .deleted => return null,
        };
        const number = value_ops.numberValue(value) orelse return null;
        const code_point = validStringCodePoint(number) orelse return error.RangeError;
        if (code_points[index] == null) seen += 1;
        code_points[index] = code_point;
    }
    if (seen != length) return null;

    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.memory.allocator);
    try units.ensureTotalCapacity(rt.memory.allocator, length * 2);
    for (code_points) |maybe_code_point| {
        appendCodePointUnits(&units, maybe_code_point.?);
    }
    return (try core.string.String.createUtf16(rt, units.items)).value();
}

pub fn validStringCodePoint(number: f64) ?u32 {
    if (std.math.isNan(number) or !std.math.isFinite(number) or number < 0 or number > 0x10ffff or @trunc(number) != number) {
        return null;
    }
    return @intFromFloat(number);
}

pub fn appendCodePointUnits(units: *std.ArrayList(u16), code_point: u32) void {
    if (code_point <= 0xffff) {
        units.appendAssumeCapacity(@intCast(code_point));
    } else {
        const adjusted = code_point - 0x10000;
        units.appendAssumeCapacity(@intCast(0xd800 + (adjusted >> 10)));
        units.appendAssumeCapacity(@intCast(0xdc00 + (adjusted & 0x3ff)));
    }
}

pub fn qjsStringFromCharCode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len == 1) {
        if (args[0].asInt32()) |code| {
            const unit: u16 = @intCast(@as(u32, @bitCast(code)) & 0xffff);
            if (unit <= 0xff) {
                const byte: u8 = @intCast(unit);
                if (try ctx.runtime.singleByteString(byte)) |cached| return cached.value().dup();
                return (try core.string.String.createAscii(ctx.runtime, &.{byte})).value();
            }
            return (try core.string.String.createUtf16(ctx.runtime, &.{unit})).value();
        }
    }
    if (args.len == 2) {
        if (args[0].asInt32()) |first_code| {
            if (args[1].asInt32()) |second_code| {
                const cached = try ctx.runtime.recentTwoUnitString(
                    @intCast(@as(u32, @bitCast(first_code)) & 0xffff),
                    @intCast(@as(u32, @bitCast(second_code)) & 0xffff),
                );
                return cached.value().dup();
            }
        }
    }
    var units: []u16 = &.{};
    if (args.len != 0) units = try ctx.runtime.memory.alloc(u16, args.len);
    defer if (units.len != 0) ctx.runtime.memory.free(u16, units);
    for (args, 0..) |value, index| {
        const primitive = try toPrimitiveForNumber(ctx, output, global, value);
        defer primitive.free(ctx.runtime);
        if (primitive.isBigInt()) return error.TypeError;
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        defer number_value.free(ctx.runtime);
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        units[index] = toUint16CodeUnit(number);
    }
    return (try core.string.String.createUtf16(ctx.runtime, units)).value();
}

pub fn qjsRegExpNativeBuiltinMatches(value: core.JSValue, expected_id: u32) bool {
    const function_object = objectFromValue(value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return false;
    return native_ref.domain == .regexp and native_ref.id == expected_id;
}

pub fn qjsRegExpAutoInitBuiltinMatches(info: core.property.AutoInit, expected_id: u32) bool {
    if (info.kind != .native_function) return false;
    const native_ref = core.function.decodeNativeBuiltinId(info.native_builtin_id) orelse return false;
    return native_ref.domain == .regexp and native_ref.id == expected_id;
}

pub fn qjsRegExpToString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!this_value.isObject()) return error.TypeError;

    const source_atom = try ctx.runtime.internAtom("source");
    defer ctx.runtime.atoms.free(source_atom);
    const source_value = try getValueProperty(ctx, output, global, this_value, source_atom, caller_function, caller_frame);
    defer source_value.free(ctx.runtime);
    const source_string = try toStringForAnnexB(ctx, output, global, source_value, caller_function, caller_frame);
    defer source_string.free(ctx.runtime);

    const flags_atom = try ctx.runtime.internAtom("flags");
    defer ctx.runtime.atoms.free(flags_atom);
    const flags_value = try getValueProperty(ctx, output, global, this_value, flags_atom, caller_function, caller_frame);
    defer flags_value.free(ctx.runtime);
    const flags_string = try toStringForAnnexB(ctx, output, global, flags_value, caller_function, caller_frame);
    defer flags_string.free(ctx.runtime);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);
    try bytes.append(ctx.runtime.memory.allocator, '/');
    try value_ops.appendRawString(ctx.runtime, &bytes, source_string);
    try bytes.append(ctx.runtime.memory.allocator, '/');
    try value_ops.appendRawString(ctx.runtime, &bytes, flags_string);
    return value_ops.createStringValue(ctx.runtime, bytes.items);
}

const SimpleLatin1LiteralPlusLiteral = struct {
    repeat: u8,
    tail: ?u8,
};

fn isPlainLatin1RegExpLiteral(unit: u8) bool {
    return unit >= 0x80 or isPlainAsciiRegExpLiteral(unit);
}

fn parseSimpleLatin1LiteralPlusLiteral(source: []const u8, flags: []const u8) ?SimpleLatin1LiteralPlusLiteral {
    if (flags.len != 0 or source.len < 2 or source[1] != '+') return null;
    const repeat = source[0];
    if (!isPlainLatin1RegExpLiteral(repeat)) return null;

    if (source.len == 2) {
        return .{ .repeat = repeat, .tail = null };
    }

    if (source.len != 3) return null;
    const tail = source[2];
    if (!isPlainLatin1RegExpLiteral(tail)) return null;
    return .{ .repeat = repeat, .tail = tail };
}

pub fn simpleLatin1LiteralPlusLiteralMatch(source: []const u8, flags: []const u8, string_value: core.JSValue) ?bool {
    const pattern = parseSimpleLatin1LiteralPlusLiteral(source, flags) orelse return null;
    const header = string_value.refHeader() orelse return null;
    if (!string_value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| simpleLatin1LiteralPlusLiteralMatchBytesPattern(pattern, bytes),
        .utf16 => |units| simpleLatin1LiteralPlusLiteralMatchUtf16Pattern(pattern, units),
    };
}

pub fn simpleLatin1LiteralPlusLiteralMatchBytes(source: []const u8, flags: []const u8, input: []const u8) ?bool {
    const pattern = parseSimpleLatin1LiteralPlusLiteral(source, flags) orelse return null;
    return simpleLatin1LiteralPlusLiteralMatchBytesPattern(pattern, input);
}

fn simpleLatin1LiteralPlusLiteralMatchBytesPattern(pattern: SimpleLatin1LiteralPlusLiteral, input: []const u8) bool {
    const repeat = pattern.repeat;
    if (pattern.tail == null) return std.mem.indexOfScalar(u8, input, repeat) != null;
    const tail = pattern.tail.?;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != repeat) continue;
        var j = i + 1;
        while (j < input.len and input[j] == repeat) : (j += 1) {}
        if (j < input.len and input[j] == tail) return true;
    }
    return false;
}

fn simpleLatin1LiteralPlusLiteralMatchUtf16Pattern(pattern: SimpleLatin1LiteralPlusLiteral, input: []const u16) bool {
    const repeat: u16 = pattern.repeat;
    if (pattern.tail == null) return std.mem.indexOfScalar(u16, input, repeat) != null;
    const tail: u16 = pattern.tail.?;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != repeat) continue;
        var j = i + 1;
        while (j < input.len and input[j] == repeat) : (j += 1) {}
        if (j < input.len and input[j] == tail) return true;
    }
    return false;
}

pub fn simpleAsciiLiteralPlusLiteralMatch(source: []const u8, flags: []const u8, string_value: core.JSValue) ?bool {
    return simpleLatin1LiteralPlusLiteralMatch(source, flags, string_value);
}

pub fn simpleAsciiLiteralPlusLiteralMatchBytes(source: []const u8, flags: []const u8, input: []const u8) ?bool {
    return simpleLatin1LiteralPlusLiteralMatchBytes(source, flags, input);
}

pub fn simpleAsciiLiteralClassPlusLiteralMatchBytes(pattern: SimpleAsciiLiteralClassPlusLiteral, input: []const u8) bool {
    var search_start: usize = 0;
    while (search_start <= input.len) {
        const start = if (pattern.prefix.len == 0) search_start else blk: {
            const relative = std.mem.indexOf(u8, input[search_start..], pattern.prefix) orelse return false;
            break :blk search_start + relative;
        };

        var class_end = start + pattern.prefix.len;
        const class_min_end = class_end + 1;
        while (class_end < input.len and builtins.regexp.classMatchesUtf16Unit(pattern.class_source, input[class_end])) : (class_end += 1) {}
        if (class_end >= class_min_end) {
            if (pattern.suffix.len == 0) return true;

            var suffix_start = class_end;
            while (suffix_start >= class_min_end) {
                if (suffix_start + pattern.suffix.len <= input.len and std.mem.eql(u8, input[suffix_start .. suffix_start + pattern.suffix.len], pattern.suffix)) {
                    return true;
                }
                if (suffix_start == class_min_end) break;
                suffix_start -= 1;
            }
        }

        search_start = start + 1;
    }
    return false;
}

pub fn latin1StringSlice(value: core.JSValue) ?[]const u8 {
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| bytes,
        .utf16 => null,
    };
}

pub fn regexpInternalStringValue(object: *core.Object, source: bool) !core.JSValue {
    if (source) {
        return (object.regexpSource() orelse return error.TypeError).dup();
    }
    return (object.regexpFlags() orelse return error.TypeError).dup();
}

pub fn qjsRegExpSymbolSearch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!this_value.isObject()) return error.TypeError;
    const string_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, string_input, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    return try qjsRegExpSymbolSearchGeneric(ctx, output, global, this_value, string_value, caller_function, caller_frame);
}

pub fn qjsRegExpSymbolMatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!this_value.isObject()) return error.TypeError;
    const string_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, string_input, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    return try qjsRegExpSymbolMatchGeneric(ctx, output, global, this_value, string_value, caller_function, caller_frame);
}

pub fn qjsRegExpSymbolMatchAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!this_value.isObject()) return error.TypeError;
    const string_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, string_input, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);

    const constructor_value = try qjsRegExpSpeciesConstructor(ctx, output, global, this_value, caller_function, caller_frame);
    defer constructor_value.free(ctx.runtime);

    const flags_atom = core.atom.predefinedId("flags", .string) orelse return error.TypeError;
    const flags_value = try getValueProperty(ctx, output, global, this_value, flags_atom, caller_function, caller_frame);
    defer flags_value.free(ctx.runtime);
    const flags_string = try toStringForAnnexB(ctx, output, global, flags_value, caller_function, caller_frame);
    defer flags_string.free(ctx.runtime);

    const construct_args = [_]core.JSValue{ this_value, flags_string };
    const matcher = try constructValueOrBytecode(ctx, output, global, constructor_value, &construct_args, caller_function, caller_frame);
    var matcher_owned = true;
    errdefer if (matcher_owned) matcher.free(ctx.runtime);

    const last_index_value = try getValueProperty(ctx, output, global, this_value, core.atom.ids.lastIndex, caller_function, caller_frame);
    defer last_index_value.free(ctx.runtime);
    const last_index = try toLengthIndex(ctx, output, global, last_index_value);
    try setValuePropertyStrict(ctx, output, global, matcher, core.atom.ids.lastIndex, uint32NumberValue(toUint32Number(@floatFromInt(last_index))), caller_function, caller_frame);

    const prototype = try qjsRegExpStringIteratorPrototype(ctx.runtime, global);
    var prototype_owned = true;
    errdefer if (prototype_owned) prototype.value().free(ctx.runtime);
    const iterator = try core.Object.create(ctx.runtime, core.class.ids.regexp_string_iterator, prototype);
    prototype.value().free(ctx.runtime);
    prototype_owned = false;
    errdefer core.Object.destroyFromHeader(ctx.runtime, &iterator.header);
    try iterator.setOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot(), matcher);
    matcher_owned = false;
    try iterator.setOptionalValueSlot(ctx.runtime, iterator.iteratorDataSlot(), string_value.dup());
    const global_flag = try qjsStringValueContainsByte(ctx.runtime, flags_string, 'g');
    const unicode_flag = try regExpFlagsAreFullUnicode(ctx.runtime, flags_string);
    iterator.iteratorKindSlot().* = (if (global_flag) @as(u8, 1) else 0) | (if (unicode_flag) @as(u8, 2) else 0);
    iterator.iteratorIndexSlot().* = 0;
    return iterator.value();
}

pub fn qjsStringMatchAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);

    const regexp = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const match_all_atom = core.atom.predefinedId("Symbol.matchAll", .symbol) orelse return error.TypeError;
    if (!regexp.isUndefined() and !regexp.isNull() and regexp.isObject()) {
        const matcher = try getValueProperty(ctx, output, global, regexp, match_all_atom, caller_function, caller_frame);
        defer matcher.free(ctx.runtime);
        if (try isRegExpObservable(ctx, output, global, regexp, caller_function, caller_frame)) {
            const flags_atom = core.atom.predefinedId("flags", .string) orelse return error.TypeError;
            const flags_value = try getValueProperty(ctx, output, global, regexp, flags_atom, caller_function, caller_frame);
            defer flags_value.free(ctx.runtime);
            if (flags_value.isUndefined() or flags_value.isNull()) return error.TypeError;
            const flags_string = try toStringForAnnexB(ctx, output, global, flags_value, caller_function, caller_frame);
            defer flags_string.free(ctx.runtime);
            if (!try qjsStringValueContainsByte(ctx.runtime, flags_string, 'g')) return error.TypeError;
        }
        if (!matcher.isUndefined() and !matcher.isNull()) {
            return callValueOrBytecode(ctx, output, global, regexp, matcher, &.{string_value}, caller_function, caller_frame);
        }
    }

    const flags = try value_ops.createStringValue(ctx.runtime, "g");
    defer flags.free(ctx.runtime);
    const matcher = try builtins.regexp.constructWithPrototype(ctx.runtime, regexp, flags, constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"));
    defer matcher.free(ctx.runtime);
    const match_all = try getValueProperty(ctx, output, global, matcher, match_all_atom, caller_function, caller_frame);
    defer match_all.free(ctx.runtime);
    if (match_all.isUndefined() or match_all.isNull()) return error.TypeError;
    return callValueOrBytecode(ctx, output, global, matcher, match_all, &.{string_value}, caller_function, caller_frame);
}

pub fn qjsRegExpStringIteratorPrototype(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    const proto = try qjsIteratorPrototype(rt, global, "RegExp String Iterator");
    errdefer core.Object.destroyFromHeader(rt, &proto.header);
    const next = try builtins.function.nativeFunction(rt, "next", 0);
    defer next.free(rt);
    try proto.defineOwnProperty(rt, core.atom.predefinedId("next", .string).?, core.Descriptor.data(next, true, false, true));
    return proto;
}

pub fn qjsRegExpSymbolReplace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!this_value.isObject()) return error.TypeError;
    const string_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, string_input, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    const replace_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    return try qjsRegExpSymbolReplaceGeneric(ctx, output, global, this_value, string_value, replace_value, caller_function, caller_frame);
}

pub fn qjsRegExpSymbolSplit(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!this_value.isObject()) return error.TypeError;
    const string_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, string_input, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);

    const constructor_value = try qjsRegExpSpeciesConstructor(ctx, output, global, this_value, caller_function, caller_frame);
    defer constructor_value.free(ctx.runtime);
    const flags_string = try qjsRegExpSplitFlags(ctx, output, global, this_value, caller_function, caller_frame);
    defer flags_string.free(ctx.runtime);
    const construct_args = [_]core.JSValue{ this_value, flags_string };
    const splitter = try constructValueOrBytecode(ctx, output, global, constructor_value, &construct_args, caller_function, caller_frame);
    defer splitter.free(ctx.runtime);

    var limit_value = core.JSValue.undefinedValue();
    if (args.len >= 2 and !args[1].isUndefined()) {
        const primitive = try toPrimitiveForNumber(ctx, output, global, args[1]);
        defer primitive.free(ctx.runtime);
        if (primitive.isBigInt()) return error.TypeError;
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        defer number_value.free(ctx.runtime);
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        limit_value = uint32NumberValue(toUint32Number(number));
    }
    const limit = if (limit_value.isUndefined()) std.math.maxInt(u32) else toUint32Number(value_ops.numberValue(limit_value) orelse std.math.nan(f64));
    if (limit == 0) {
        const out = try core.Object.createArray(ctx.runtime, null);
        return out.value();
    }
    const unicode_matching = try regExpFlagsAreFullUnicode(ctx.runtime, flags_string);
    if (try qjsRegExpSymbolSplitGeneric(ctx, output, global, splitter, string_value, limit, unicode_matching, caller_function, caller_frame)) |result| return result;
    if (try qjsRegExpSplit(ctx.runtime, this_value, string_value, limit_value)) |result| return result;
    return try qjsRegExpSplitWholeString(ctx.runtime, string_value);
}

pub fn qjsRegExpSplitFlags(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const flags_string = try getRegExpFlagsString(ctx, output, global, rx, caller_function, caller_frame);
    defer flags_string.free(ctx.runtime);

    var flags = std.ArrayList(u8).empty;
    defer flags.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &flags, flags_string);
    if (std.mem.indexOfScalar(u8, flags.items, 'y') == null) {
        try flags.append(ctx.runtime.memory.allocator, 'y');
    }
    return value_ops.createStringValue(ctx.runtime, flags.items);
}

pub fn qjsStringValueContainsByte(rt: *core.JSRuntime, string_value: core.JSValue, needle: u8) !bool {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &bytes, string_value);
    return std.mem.indexOfScalar(u8, bytes.items, needle) != null;
}

pub fn qjsRegExpSymbolSplitGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    splitter: core.JSValue,
    string_value: core.JSValue,
    limit: u32,
    unicode_matching: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &units, string_value);

    const out = try core.Object.createArray(ctx.runtime, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    var out_index: u32 = 0;

    if (units.items.len == 0) {
        const result = qjsRegExpExecGeneric(ctx, output, global, splitter, string_value, caller_function, caller_frame) catch |err| switch (err) {
            error.TypeError => {
                core.Object.destroyFromHeader(ctx.runtime, &out.header);
                return null;
            },
            else => return err,
        };
        defer result.free(ctx.runtime);
        if (result.isNull()) try defineSplitUnitsElement(ctx.runtime, out, out_index, units.items);
        return out.value();
    }

    var start: usize = 0;
    var pos: usize = 0;
    while (pos < units.items.len) {
        try setValuePropertyStrict(ctx, output, global, splitter, core.atom.ids.lastIndex, core.JSValue.int32(@intCast(pos)), caller_function, caller_frame);
        const result = qjsRegExpExecGeneric(ctx, output, global, splitter, string_value, caller_function, caller_frame) catch |err| switch (err) {
            error.TypeError => {
                core.Object.destroyFromHeader(ctx.runtime, &out.header);
                return null;
            },
            else => return err,
        };
        defer result.free(ctx.runtime);
        if (result.isNull()) {
            pos = advanceStringIndexUnits(units.items, pos, unicode_matching);
            continue;
        }

        const end_value = try getValueProperty(ctx, output, global, splitter, core.atom.ids.lastIndex, caller_function, caller_frame);
        defer end_value.free(ctx.runtime);
        var end = try toLengthIndex(ctx, output, global, end_value);
        if (end > units.items.len) end = units.items.len;
        if (end == start) {
            pos = advanceStringIndexUnits(units.items, pos, unicode_matching);
            continue;
        }

        try defineSplitUnitsElement(ctx.runtime, out, out_index, units.items[start..pos]);
        out_index += 1;
        if (out_index >= limit) return out.value();
        start = end;

        const length_value = try getValueProperty(ctx, output, global, result, core.atom.ids.length, caller_function, caller_frame);
        defer length_value.free(ctx.runtime);
        const capture_limit = try toLengthIndex(ctx, output, global, length_value);
        var capture_index: usize = 1;
        while (capture_index < capture_limit) : (capture_index += 1) {
            const capture = try getValueProperty(ctx, output, global, result, core.atom.atomFromUInt32(@intCast(capture_index)), caller_function, caller_frame);
            defer capture.free(ctx.runtime);
            if (capture.isUndefined()) {
                try defineSplitValueElement(ctx.runtime, out, out_index, core.JSValue.undefinedValue());
            } else {
                const capture_string = try toStringForAnnexB(ctx, output, global, capture, caller_function, caller_frame);
                defer capture_string.free(ctx.runtime);
                try defineSplitValueElement(ctx.runtime, out, out_index, capture_string);
            }
            out_index += 1;
            if (out_index >= limit) return out.value();
        }
        pos = start;
    }

    const tail_start = @min(start, units.items.len);
    try defineSplitUnitsElement(ctx.runtime, out, out_index, units.items[tail_start..]);
    return out.value();
}

pub fn advanceStringIndexUnits(units: []const u16, index: usize, unicode: bool) usize {
    if (!unicode or index + 1 >= units.len) return index + 1;
    const first = units[index];
    if (first < 0xd800 or first > 0xdbff) return index + 1;
    const second = units[index + 1];
    return if (second >= 0xdc00 and second <= 0xdfff) index + 2 else index + 1;
}

pub fn qjsRegExpSymbolSearchGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const previous = try getValueProperty(ctx, output, global, rx, core.atom.ids.lastIndex, caller_function, caller_frame);
    defer previous.free(ctx.runtime);
    if (!builtins.object.sameValue(previous, core.JSValue.int32(0))) {
        try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    }

    const result = if (try qjsRegExpExecSimpleUnicodeLiteral(ctx, output, global, rx, string_value, caller_function, caller_frame)) |value|
        value
    else
        try qjsRegExpExecGeneric(ctx, output, global, rx, string_value, caller_function, caller_frame);
    defer result.free(ctx.runtime);

    const current = try getValueProperty(ctx, output, global, rx, core.atom.ids.lastIndex, caller_function, caller_frame);
    defer current.free(ctx.runtime);
    if (!builtins.object.sameValue(current, previous)) {
        try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, previous, caller_function, caller_frame);
    }

    if (result.isNull()) return core.JSValue.int32(-1);
    if (!result.isObject()) return error.TypeError;
    const index_atom = core.atom.predefinedId("index", .string) orelse return error.TypeError;
    return getValueProperty(ctx, output, global, result, index_atom, caller_function, caller_frame);
}

pub fn qjsRegExpSymbolMatchGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const flags_string = try getRegExpFlagsString(ctx, output, global, rx, caller_function, caller_frame);
    defer flags_string.free(ctx.runtime);

    var flags = std.ArrayList(u8).empty;
    defer flags.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &flags, flags_string);
    if (std.mem.indexOfScalar(u8, flags.items, 'g') == null) {
        if (try qjsRegExpExecSimpleUnicodeLiteral(ctx, output, global, rx, string_value, caller_function, caller_frame)) |value| return value;
        return qjsRegExpExecGeneric(ctx, output, global, rx, string_value, caller_function, caller_frame);
    }

    const full_unicode = try regExpFlagsAreFullUnicode(ctx.runtime, flags_string);
    try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);

    const out = try core.Object.createArray(ctx.runtime, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    var count: u32 = 0;
    while (true) {
        const result = try qjsRegExpExecGeneric(ctx, output, global, rx, string_value, caller_function, caller_frame);
        defer result.free(ctx.runtime);
        if (result.isNull()) break;
        const zero_value = try getValueProperty(ctx, output, global, result, core.atom.atomFromUInt32(0), caller_function, caller_frame);
        defer zero_value.free(ctx.runtime);
        const match_string = try toStringForAnnexB(ctx, output, global, zero_value, caller_function, caller_frame);
        defer match_string.free(ctx.runtime);
        try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(count), core.Descriptor.data(match_string, true, true, true));
        count += 1;
        if (isEmptyStringValue(ctx.runtime, match_string)) {
            const last_index = try getValueProperty(ctx, output, global, rx, core.atom.ids.lastIndex, caller_function, caller_frame);
            defer last_index.free(ctx.runtime);
            const next = try advanceStringIndexNumber(ctx, output, global, string_value, last_index, full_unicode);
            try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, next, caller_function, caller_frame);
        }
    }
    if (count == 0) return core.JSValue.nullValue();
    return out.value();
}

pub const ReplaceMatch = struct {
    result: core.JSValue,
    matched: core.JSValue,
    index: usize,
    captures: []core.JSValue,
    groups: core.JSValue,
};

pub fn qjsRegExpSymbolReplaceGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    replace_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const functional_replace = isCallableValue(replace_value);
    const replacement_string = if (functional_replace)
        core.JSValue.undefinedValue()
    else
        try toStringForAnnexB(ctx, output, global, replace_value, caller_function, caller_frame);
    defer if (!functional_replace) replacement_string.free(ctx.runtime);

    const flags_string = try getRegExpFlagsStringForReplace(ctx, output, global, rx, caller_function, caller_frame);
    defer flags_string.free(ctx.runtime);
    const is_global = try qjsStringValueContainsByte(ctx.runtime, flags_string, 'g');
    const full_unicode = try regExpFlagsAreFullUnicode(ctx.runtime, flags_string);
    if (is_global) {
        try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    }
    if (is_global and !functional_replace) {
        if (objectFromValue(rx)) |regexp_object| {
            var source = std.ArrayList(u8).empty;
            defer source.deinit(ctx.runtime.memory.allocator);
            if (try appendRegExpSource(ctx.runtime, regexp_object, &source)) {
                if (replaceSingleUnitGlobalSimpleClassEscape(string_value, replacement_string, source.items)) |fast| return fast;
                if (try replaceGlobalSimpleClassEscape(ctx.runtime, string_value, replacement_string, source.items)) |fast| return fast;
            }
            if (try replaceGlobalSimpleCaptureSequence(ctx, output, global, rx, regexp_object, string_value, replacement_string, flags_string, caller_function, caller_frame)) |fast| return fast;
        }
    }

    var matches = std.ArrayList(ReplaceMatch).empty;
    defer matches.deinit(ctx.runtime.memory.allocator);
    defer {
        freeReplaceMatches(ctx.runtime, matches.items);
    }

    while (true) {
        const result = try qjsRegExpExecGeneric(ctx, output, global, rx, string_value, caller_function, caller_frame);
        if (result.isNull()) {
            result.free(ctx.runtime);
            break;
        }
        if (!result.isObject()) {
            result.free(ctx.runtime);
            return error.TypeError;
        }
        const match = try captureReplaceMatch(ctx, output, global, result, string_value, caller_function, caller_frame);
        try matches.append(ctx.runtime.memory.allocator, match);
        if (!is_global) break;
        if (isEmptyStringValue(ctx.runtime, match.matched)) {
            const last_index = try getValueProperty(ctx, output, global, rx, core.atom.ids.lastIndex, caller_function, caller_frame);
            defer last_index.free(ctx.runtime);
            const next = try advanceStringIndexNumber(ctx, output, global, string_value, last_index, full_unicode);
            try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, next, caller_function, caller_frame);
        }
    }
    if (matches.items.len == 0) return string_value.dup();

    var source_units = std.ArrayList(u16).empty;
    defer source_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &source_units, string_value);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    var next_source_position: usize = 0;
    for (matches.items) |match| {
        const matched_len = try stringLengthIndex(ctx.runtime, match.matched);
        const position = @min(match.index, source_units.items.len);
        if (position < next_source_position) continue;
        try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[next_source_position..position]);

        const replacement = if (functional_replace)
            try callReplaceFunction(ctx, output, global, replace_value, match, string_value, caller_function, caller_frame)
        else
            try getSubstitutionString(ctx, output, global, match, string_value, replacement_string, caller_function, caller_frame);
        defer replacement.free(ctx.runtime);
        try appendStringValueUnits(ctx.runtime, &out, replacement);
        next_source_position = @min(source_units.items.len, position + matched_len);
    }
    try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[next_source_position..]);
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn replaceSingleUnitGlobalSimpleClassEscape(
    string_value: core.JSValue,
    replacement_string: core.JSValue,
    source: []const u8,
) ?core.JSValue {
    if (!classEscapeIsQuantified(source) or !isSimpleStringClassEscapeSource(source)) return null;
    const header = string_value.refHeader() orelse return null;
    if (!string_value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    const unit = switch (string_object.resolveData()) {
        .latin1 => |bytes| blk: {
            if (bytes.len != 1) return null;
            break :blk @as(u16, bytes[0]);
        },
        .utf16 => |units| blk: {
            if (units.len != 1) return null;
            break :blk units[0];
        },
    };
    return if (classEscapeUnitMatches(source, unit)) replacement_string.dup() else string_value.dup();
}

pub fn replaceGlobalSimpleClassEscape(
    rt: *core.JSRuntime,
    string_value: core.JSValue,
    replacement_string: core.JSValue,
    source: []const u8,
) !?core.JSValue {
    if (!classEscapeIsQuantified(source) or !isSimpleStringClassEscapeSource(source)) return null;
    const header = string_value.refHeader() orelse return null;
    if (!string_value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);

    var replacement_units = std.ArrayList(u16).empty;
    defer replacement_units.deinit(rt.memory.allocator);
    try appendStringValueUnits(rt, &replacement_units, replacement_string);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(rt.memory.allocator);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            var index: usize = 0;
            while (index < bytes.len) {
                const unit: u16 = bytes[index];
                if (classEscapeUnitMatches(source, unit)) {
                    try out.appendSlice(rt.memory.allocator, replacement_units.items);
                    index += classEscapeRunLengthLatin1(source, bytes, index);
                } else {
                    try out.append(rt.memory.allocator, unit);
                    index += 1;
                }
            }
        },
        .utf16 => |units| {
            var index: usize = 0;
            while (index < units.len) {
                const unit = units[index];
                if (classEscapeUnitMatches(source, unit)) {
                    try out.appendSlice(rt.memory.allocator, replacement_units.items);
                    index += classEscapeRunLengthUtf16(source, units, index);
                } else {
                    try out.append(rt.memory.allocator, unit);
                    index += 1;
                }
            }
        },
    }
    return (try core.string.String.createUtf16(rt, out.items)).value();
}

pub const FastReplacementPart = union(enum) {
    literal: []const u8,
    capture: usize,
    dollar,
};

pub const FastReplacementPattern = struct {
    parts: [32]FastReplacementPart = undefined,
    len: usize = 0,

    pub fn append(self: *FastReplacementPattern, part: FastReplacementPart) bool {
        if (self.len >= self.parts.len) return false;
        self.parts[self.len] = part;
        self.len += 1;
        return true;
    }
};

pub fn replaceGlobalSimpleCaptureSequence(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    replacement_string: core.JSValue,
    flags_string: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return null;
    const observed_flags = latin1StringSlice(flags_string) orelse return null;
    if (!std.mem.eql(u8, observed_flags, borrowed.flags)) return null;
    if (std.mem.indexOfScalar(u8, borrowed.flags, 'g') == null) return null;
    if (std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null) return null;
    if (!try regExpExecPropertyIsDefault(ctx, output, global, rx, caller_function, caller_frame)) return null;

    const pattern = regexpSimpleCaptureSequencePattern(regexp_object, borrowed.source, borrowed.flags) orelse return null;
    const input = latin1StringSlice(string_value) orelse return null;
    const replacement = latin1StringSlice(replacement_string) orelse return null;
    const replacement_pattern = parseFastReplacementPattern(replacement, pattern.capture_count) orelse return null;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    var next_source_position: usize = 0;
    var search_start: usize = 0;
    var last_match: ?RegExpMatch = null;

    while (search_start <= input.len) {
        const found = simpleCaptureSequenceMatchLatin1(pattern, input, search_start, false, borrowed.flags) orelse break;
        if (found.index < next_source_position) break;
        try out.appendSlice(ctx.runtime.memory.allocator, input[next_source_position..found.index]);
        try appendFastReplacement(ctx.runtime, &out, input, found, replacement_pattern);
        next_source_position = found.index + found.len;
        last_match = found;
        search_start = if (found.len == 0) @min(input.len + 1, found.index + 1) else next_source_position;
    }

    const final_match = last_match orelse return string_value.dup();
    try out.appendSlice(ctx.runtime.memory.allocator, input[next_source_position..]);
    try updateRegExpLegacyStaticsForMatch(ctx.runtime, global, string_value, final_match);
    return (try core.string.String.createLatin1(ctx.runtime, out.items)).value();
}

pub fn parseFastReplacementPattern(replacement: []const u8, capture_count: usize) ?FastReplacementPattern {
    var pattern = FastReplacementPattern{};
    var literal_start: usize = 0;
    var index: usize = 0;
    while (index < replacement.len) {
        if (replacement[index] != '$') {
            index += 1;
            continue;
        }
        if (index + 1 >= replacement.len) return null;
        const next = replacement[index + 1];
        switch (next) {
            '$' => {
                if (literal_start < index and !pattern.append(.{ .literal = replacement[literal_start..index] })) return null;
                if (!pattern.append(.dollar)) return null;
                index += 2;
                literal_start = index;
            },
            '1'...'9' => {
                var capture_index: usize = next - '0';
                var consumed: usize = 1;
                if (index + 2 < replacement.len and std.ascii.isDigit(replacement[index + 2])) {
                    const two_digit = capture_index * 10 + (replacement[index + 2] - '0');
                    if (two_digit >= 1 and two_digit <= capture_count) {
                        capture_index = two_digit;
                        consumed = 2;
                    }
                }
                if (capture_index == 0 or capture_index > capture_count) return null;
                if (literal_start < index and !pattern.append(.{ .literal = replacement[literal_start..index] })) return null;
                if (!pattern.append(.{ .capture = capture_index - 1 })) return null;
                index += 1 + consumed;
                literal_start = index;
            },
            else => return null,
        }
    }
    if (literal_start < replacement.len and !pattern.append(.{ .literal = replacement[literal_start..] })) return null;
    return pattern;
}

pub fn appendFastReplacement(rt: *core.JSRuntime, out: *std.ArrayList(u8), input: []const u8, found: RegExpMatch, replacement: FastReplacementPattern) !void {
    for (replacement.parts[0..replacement.len]) |part| {
        switch (part) {
            .literal => |bytes| try out.appendSlice(rt.memory.allocator, bytes),
            .dollar => try out.append(rt.memory.allocator, '$'),
            .capture => |capture_index| {
                if (capture_index >= found.capture_count) continue;
                const capture = found.captures[capture_index];
                if (capture.undefined) continue;
                try out.appendSlice(rt.memory.allocator, input[capture.start .. capture.start + capture.len]);
            },
        }
    }
}

pub fn appendStringValueUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), value: core.JSValue) !void {
    const header = value.refHeader() orelse {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try value_ops.appendRawString(rt, &bytes, value);
        for (bytes.items) |byte| try out.append(rt.memory.allocator, byte);
        return;
    };
    if (!value.isString()) {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try value_ops.appendRawString(rt, &bytes, value);
        for (bytes.items) |byte| try out.append(rt.memory.allocator, byte);
        return;
    }
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| for (bytes) |byte| try out.append(rt.memory.allocator, byte),
        .utf16 => |units| try out.appendSlice(rt.memory.allocator, units),
    }
}

pub fn stringValueContainsUnitByte(value: core.JSValue, needle: u8) bool {
    if (!value.isString()) return false;
    const header = value.refHeader() orelse return false;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| std.mem.indexOfScalar(u8, bytes, needle) != null,
        .utf16 => |units| blk: {
            for (units) |unit| {
                if (unit == needle) break :blk true;
            }
            break :blk false;
        },
    };
}

pub fn stringValueUnitsEqualBytes(value: core.JSValue, expected: []const u8) bool {
    if (!value.isString()) return false;
    const header = value.refHeader() orelse return false;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| std.mem.eql(u8, bytes, expected),
        .utf16 => |units| blk: {
            if (units.len != expected.len) break :blk false;
            for (units, expected) |unit, byte| {
                if (unit != byte) break :blk false;
            }
            break :blk true;
        },
    };
}

pub fn getRegExpFlagsStringForReplace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return getRegExpFlagsString(ctx, output, global, rx, caller_function, caller_frame);
}

pub fn getRegExpFlagsString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const flags_atom = try ctx.runtime.internAtom("flags");
    defer ctx.runtime.atoms.free(flags_atom);
    const flags_value = try getValueProperty(ctx, output, global, rx, flags_atom, caller_function, caller_frame);
    defer flags_value.free(ctx.runtime);
    return toStringForAnnexB(ctx, output, global, flags_value, caller_function, caller_frame);
}

pub fn captureReplaceMatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    result: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !ReplaceMatch {
    errdefer result.free(ctx.runtime);
    const matched_value = try getValueProperty(ctx, output, global, result, core.atom.atomFromUInt32(0), caller_function, caller_frame);
    errdefer matched_value.free(ctx.runtime);
    const matched = try toStringForAnnexB(ctx, output, global, matched_value, caller_function, caller_frame);
    matched_value.free(ctx.runtime);
    errdefer matched.free(ctx.runtime);

    const index_atom = core.atom.predefinedId("index", .string) orelse return error.TypeError;
    const index_value = try getValueProperty(ctx, output, global, result, index_atom, caller_function, caller_frame);
    defer index_value.free(ctx.runtime);
    const string_len = try stringLengthIndex(ctx.runtime, string_value);
    const index = @min(try toLengthIndex(ctx, output, global, index_value), string_len);

    const length_value = try getValueProperty(ctx, output, global, result, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try toLengthIndex(ctx, output, global, length_value);
    const capture_count = if (length == 0) 0 else length - 1;
    var captures: []core.JSValue = &.{};
    if (capture_count != 0) {
        captures = try ctx.runtime.memory.alloc(core.JSValue, capture_count);
        errdefer ctx.runtime.memory.free(core.JSValue, captures);
        var rooted_captures: []core.JSValue = captures[0..0];
        var captures_root = ValueSliceRoot{};
        captures_root.init(ctx.runtime, &rooted_captures);
        defer captures_root.deinit();
        var initialized: usize = 0;
        errdefer {
            for (captures[0..initialized]) |*capture| {
                capture.free(ctx.runtime);
                capture.* = core.JSValue.undefinedValue();
            }
            rooted_captures = &.{};
        }
        while (initialized < capture_count) {
            const capture_index = initialized;
            captures[capture_index] = try getValueProperty(ctx, output, global, result, core.atom.atomFromUInt32(@intCast(capture_index + 1)), caller_function, caller_frame);
            initialized += 1;
            rooted_captures = captures[0..initialized];
            if (!captures[capture_index].isUndefined()) {
                const capture_string = try toStringForAnnexB(ctx, output, global, captures[capture_index], caller_function, caller_frame);
                const old_capture = captures[capture_index];
                captures[capture_index] = capture_string;
                old_capture.free(ctx.runtime);
            }
        }
    }

    const groups_atom = core.atom.predefinedId("groups", .string) orelse return error.TypeError;
    const groups = try getValueProperty(ctx, output, global, result, groups_atom, caller_function, caller_frame);
    errdefer groups.free(ctx.runtime);
    return .{ .result = result, .matched = matched, .index = index, .captures = captures, .groups = groups };
}

pub fn freeReplaceMatches(rt: *core.JSRuntime, matches: []ReplaceMatch) void {
    for (matches) |match| {
        match.result.free(rt);
        match.matched.free(rt);
        for (match.captures) |capture| capture.free(rt);
        if (match.captures.len != 0) rt.memory.free(core.JSValue, match.captures);
        match.groups.free(rt);
    }
}

pub fn callReplaceFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    replacer: core.JSValue,
    match: ReplaceMatch,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const extra: usize = if (match.groups.isUndefined()) 2 else 3;
    const arg_count = 1 + match.captures.len + extra;
    const args = try ctx.runtime.memory.alloc(core.JSValue, arg_count);
    defer ctx.runtime.memory.free(core.JSValue, args);
    args[0] = match.matched;
    for (match.captures, 0..) |capture, index| args[index + 1] = capture;
    args[1 + match.captures.len] = core.JSValue.int32(@intCast(match.index));
    args[2 + match.captures.len] = string_value;
    if (!match.groups.isUndefined()) args[3 + match.captures.len] = match.groups;
    const result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), replacer, args, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    return toStringForAnnexB(ctx, output, global, result, caller_function, caller_frame);
}

pub fn getSubstitutionString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    match: ReplaceMatch,
    string_value: core.JSValue,
    replacement_string: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const named_captures = if (match.groups.isUndefined())
        core.JSValue.undefinedValue()
    else if (match.groups.isNull())
        return error.TypeError
    else if (match.groups.isObject())
        match.groups.dup()
    else
        try primitiveObjectForAccess(ctx.runtime, global, match.groups);
    defer if (!named_captures.isUndefined()) named_captures.free(ctx.runtime);

    var source = std.ArrayList(u16).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &source, string_value);
    var matched = std.ArrayList(u16).empty;
    defer matched.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &matched, match.matched);
    var replacement = std.ArrayList(u16).empty;
    defer replacement.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &replacement, replacement_string);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    var index: usize = 0;
    while (index < replacement.items.len) : (index += 1) {
        if (replacement.items[index] != '$' or index + 1 >= replacement.items.len) {
            try out.append(ctx.runtime.memory.allocator, replacement.items[index]);
            continue;
        }
        const next = replacement.items[index + 1];
        switch (next) {
            '$' => {
                try out.append(ctx.runtime.memory.allocator, '$');
                index += 1;
            },
            '&' => {
                try out.appendSlice(ctx.runtime.memory.allocator, matched.items);
                index += 1;
            },
            '`' => {
                try out.appendSlice(ctx.runtime.memory.allocator, source.items[0..@min(match.index, source.items.len)]);
                index += 1;
            },
            '\'' => {
                const tail_start = @min(source.items.len, match.index + matched.items.len);
                try out.appendSlice(ctx.runtime.memory.allocator, source.items[tail_start..]);
                index += 1;
            },
            '0'...'9' => {
                const capture = replacementCaptureUnits(match, replacement.items, &index) orelse {
                    try out.append(ctx.runtime.memory.allocator, '$');
                    continue;
                };
                if (!capture.isUndefined()) try appendStringValueUnits(ctx.runtime, &out, capture);
            },
            '<' => {
                if (try appendNamedCaptureSubstitution(ctx, output, global, named_captures, replacement.items, &index, &out, caller_function, caller_frame)) continue;
                try out.append(ctx.runtime.memory.allocator, '$');
            },
            else => try out.append(ctx.runtime.memory.allocator, '$'),
        }
    }
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn replacementCaptureUnits(match: ReplaceMatch, replacement: []const u16, index: *usize) ?core.JSValue {
    const first = replacement[index.* + 1];
    if (!isAsciiDigitUnit(first)) return null;
    if (first == '0') {
        if (index.* + 2 >= replacement.len or !isAsciiDigitUnit(replacement[index.* + 2])) return null;
        const two_digit: usize = @intCast(replacement[index.* + 2] - '0');
        if (two_digit == 0 or two_digit > match.captures.len) return null;
        index.* += 2;
        return match.captures[two_digit - 1];
    }
    var capture_index: usize = @intCast(first - '0');
    var consumed: usize = 1;
    if (index.* + 2 < replacement.len and isAsciiDigitUnit(replacement[index.* + 2])) {
        const two_digit = capture_index * 10 + @as(usize, @intCast(replacement[index.* + 2] - '0'));
        if (two_digit >= 1 and two_digit <= match.captures.len) {
            capture_index = two_digit;
            consumed = 2;
        }
    }
    if (capture_index == 0 or capture_index > match.captures.len) return null;
    index.* += consumed;
    return match.captures[capture_index - 1];
}

pub fn stringLengthIndex(rt: *core.JSRuntime, string_value: core.JSValue) !usize {
    const header = string_value.refHeader() orelse return 0;
    if (!string_value.isString()) return 0;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    _ = rt;
    return string_object.len();
}

pub fn isEmptyStringValue(rt: *core.JSRuntime, value: core.JSValue) bool {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    value_ops.appendRawString(rt, &bytes, value) catch return false;
    return bytes.items.len == 0;
}

pub fn advanceStringIndexNumber(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    string_value: core.JSValue,
    index_value: core.JSValue,
    unicode: bool,
) !core.JSValue {
    const index_number = try toLengthNumber(ctx, output, global, index_value);
    if (!unicode or index_number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) {
        return value_ops.numberToValue(index_number + 1);
    }
    const index: usize = @intFromFloat(index_number);
    const header = string_value.refHeader() orelse return value_ops.numberToValue(index_number + 1);
    if (!string_value.isString()) return value_ops.numberToValue(index_number + 1);
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    if (index + 1 >= string_object.len()) return value_ops.numberToValue(index_number + 1);
    const first = string_object.codeUnitAt(index);
    const second = string_object.codeUnitAt(index + 1);
    if (isHighSurrogateUnit(first) and isLowSurrogateUnit(second)) {
        return value_ops.numberToValue(index_number + 2);
    }
    return value_ops.numberToValue(index_number + 1);
}

pub fn replaceRegExpLegacySlot(rt: *core.JSRuntime, owner: *core.Object, slot: *?core.JSValue, value: core.JSValue) !void {
    if (slot.*) |old| {
        if (old.same(value)) return;
    }
    const next_value = value.dup();
    try owner.setOptionalValueSlot(rt, slot, next_value);
}

pub fn stringAtomId(value: core.JSValue) ?core.Atom {
    if (!value.isString()) return null;
    const header = value.refHeader() orelse return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return string_value.atom_id;
}

pub fn nativeFunctionMatcherUnicodeClassAsciiResult(source: []const u8, flags: []const u8, string_value: core.JSValue, start_index: usize) ?bool {
    if (flags.len != 0 or start_index != 0) return null;
    const is_id_start = std.mem.startsWith(u8, source, "(?:[A-Za-z");
    const is_id_continue = std.mem.startsWith(u8, source, "(?:[0-9A-Z_a-z");
    if (!is_id_start and !is_id_continue) return null;
    const header = string_value.refHeader() orelse return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    if (string_object.len() != 1) return null;
    const unit = string_object.codeUnitAt(0);
    if (unit > 0x7f) return null;
    const byte: u8 = @intCast(unit);
    if (byte >= 'A' and byte <= 'Z') return true;
    if (byte >= 'a' and byte <= 'z') return true;
    if (is_id_continue and byte >= '0' and byte <= '9') return true;
    if (is_id_continue and byte == '_') return true;
    return false;
}

pub fn findStringPropertyEscapeMatch(source: []const u8, string_value: core.JSValue, start_index: usize, sticky: bool) ?RegExpMatch {
    const name = stringPropertyEscapePattern(source) orelse return null;
    if (!std.mem.eql(u8, name, "RGI_Emoji")) return null;
    const units = stringValueUnits(string_value) orelse return null;
    const match = emoji.findRgiEmojiMatch(units, start_index, sticky) orelse return null;
    return .{ .index = match.index, .len = match.len };
}

pub fn anchoredRgiEmojiMatches(string_value: core.JSValue) bool {
    const units = stringValueUnits(string_value) orelse return false;
    return emoji.rgiEmojiSequencesCover(units);
}

pub fn stringValueUnits(string_value: core.JSValue) ?emoji.StringUnits {
    const header = string_value.refHeader() orelse return null;
    if (!string_value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            return .{ .latin1 = bytes };
        },
        .utf16 => |units| {
            return .{ .utf16 = units };
        },
    }
}

pub fn findPropertyEscapeMatch(source: []const u8, string_value: core.JSValue, start_index: usize, sticky: bool) ?RegExpMatch {
    const parsed = propertyEscapePattern(source) orelse return null;
    const header = string_value.refHeader() orelse return null;
    if (!string_value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            var index = start_index;
            while (index < bytes.len) {
                const code_point: u21 = bytes[index];
                if (binaryPropertyCodePointMatches(parsed.name, code_point) == parsed.positive) return .{ .index = index, .len = 1 };
                if (sticky) break;
                index += 1;
            }
        },
        .utf16 => |units| {
            var index = start_index;
            while (index < units.len) {
                var next = index;
                const code_point = readUtf16CodePoint(units, &next);
                if (binaryPropertyCodePointMatches(parsed.name, code_point) == parsed.positive) return .{ .index = index, .len = next - index };
                if (sticky) break;
                index = next;
            }
        },
    }
    return null;
}

pub fn anchoredStringPropertyName(source: []const u8) ?[]const u8 {
    const positive_prefix = "^\\p{";
    const suffix = "}+$";
    if (!std.mem.startsWith(u8, source, positive_prefix)) return null;
    if (!std.mem.endsWith(u8, source, suffix)) return null;
    if (source.len <= positive_prefix.len + suffix.len) return null;
    return source[positive_prefix.len .. source.len - suffix.len];
}

pub fn stringPropertyEscapePattern(source: []const u8) ?[]const u8 {
    const positive_prefix = "\\p{";
    if (!std.mem.startsWith(u8, source, positive_prefix)) return null;
    if (source.len <= positive_prefix.len or source[source.len - 1] != '}') return null;
    const name = source[positive_prefix.len .. source.len - 1];
    return if (std.mem.eql(u8, name, "RGI_Emoji")) name else null;
}

pub fn unicodePropertyRunCodePointMatches(pattern: UnicodePropertyRunPattern, code_point: u21) bool {
    const matched = switch (pattern.predicate) {
        .generic => binaryPropertyCodePointMatches(pattern.name, code_point),
        .greek_script => isUnicodeGreekScriptCodePoint(code_point),
    };
    return matched == pattern.positive;
}

pub fn isUnicodeGreekScriptCodePoint(code_point: u21) bool {
    return code_point == 0x00037f or
        code_point == 0x000384 or
        code_point == 0x000386 or
        code_point == 0x00038c or
        code_point == 0x001dbf or
        code_point == 0x001f59 or
        code_point == 0x001f5b or
        code_point == 0x001f5d or
        code_point == 0x002126 or
        code_point == 0x00ab65 or
        code_point == 0x0101a0 or
        (code_point >= 0x000370 and code_point <= 0x000373) or
        (code_point >= 0x000375 and code_point <= 0x000377) or
        (code_point >= 0x00037a and code_point <= 0x00037d) or
        (code_point >= 0x000388 and code_point <= 0x00038a) or
        (code_point >= 0x00038e and code_point <= 0x0003a1) or
        (code_point >= 0x0003a3 and code_point <= 0x0003e1) or
        (code_point >= 0x0003f0 and code_point <= 0x0003ff) or
        (code_point >= 0x001d26 and code_point <= 0x001d2a) or
        (code_point >= 0x001d5d and code_point <= 0x001d61) or
        (code_point >= 0x001d66 and code_point <= 0x001d6a) or
        (code_point >= 0x001f00 and code_point <= 0x001f15) or
        (code_point >= 0x001f18 and code_point <= 0x001f1d) or
        (code_point >= 0x001f20 and code_point <= 0x001f45) or
        (code_point >= 0x001f48 and code_point <= 0x001f4d) or
        (code_point >= 0x001f50 and code_point <= 0x001f57) or
        (code_point >= 0x001f5f and code_point <= 0x001f7d) or
        (code_point >= 0x001f80 and code_point <= 0x001fb4) or
        (code_point >= 0x001fb6 and code_point <= 0x001fc4) or
        (code_point >= 0x001fc6 and code_point <= 0x001fd3) or
        (code_point >= 0x001fd6 and code_point <= 0x001fdb) or
        (code_point >= 0x001fdd and code_point <= 0x001fef) or
        (code_point >= 0x001ff2 and code_point <= 0x001ff4) or
        (code_point >= 0x001ff6 and code_point <= 0x001ffe) or
        (code_point >= 0x010140 and code_point <= 0x01018e) or
        (code_point >= 0x01d200 and code_point <= 0x01d245);
}

pub fn findUnicodePropertyOnlyClassMatch(source: []const u8, string_value: core.JSValue, start_index: usize, sticky: bool) ?RegExpMatch {
    if (!unicodePropertyOnlyClassSource(source)) return null;
    const header = string_value.refHeader() orelse return null;
    if (!string_value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            var index = start_index;
            while (index < bytes.len) : (index += 1) {
                if (unicodePropertyOnlyClassCodePointMatches(source, bytes[index])) return .{ .index = index, .len = 1 };
                if (sticky) break;
            }
        },
        .utf16 => |units| {
            var index = start_index;
            while (index < units.len) {
                const match_start = index;
                const code_point = readUtf16CodePoint(units, &index);
                if (unicodePropertyOnlyClassCodePointMatches(source, code_point)) return .{ .index = match_start, .len = index - match_start };
                if (sticky) break;
            }
        },
    }
    return null;
}

pub fn unicodePropertyOnlyClassCodePointMatches(source: []const u8, code_point: u21) bool {
    const body = unicodePropertyOnlyClassBody(source) orelse return false;
    var index: usize = 0;
    while (index < body.len) {
        const parsed = readUnicodePropertyClassEscape(body, &index) orelse return false;
        if (binaryPropertyCodePointMatches(parsed.name, code_point) == parsed.positive) return true;
    }
    return false;
}

pub fn qjsStringTrim(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    return builtins.string.methodCall(ctx.runtime, string_value, method_id, &.{});
}

pub fn qjsStringPrototypeMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    if (method_id == 10) {
        return qjsStringConcat(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == builtins.string.legacy_split_method_id) {
        return qjsStringSplit(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == builtins.string.legacy_search_method_id) {
        return qjsStringSearch(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == builtins.string.legacy_match_method_id) {
        return qjsStringMatch(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == builtins.string.legacy_replace_all_method_id) {
        return qjsStringReplaceAll(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == builtins.string.legacy_match_all_method_id) {
        return qjsStringMatchAll(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == 34 or method_id == 35) {
        return qjsStringPad(ctx, output, global, this_value, method_id, args, caller_function, caller_frame);
    }
    if (method_id == 11 or method_id == 12 or method_id == 13 or method_id == 14 or method_id == 15 or
        method_id == 16 or method_id == 17 or method_id == 18 or method_id == 19 or method_id == 20 or
        method_id == 23 or method_id == 24 or method_id == 26)
    {
        return qjsStringHtmlMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame);
    }
    if (method_id == builtins.string.legacy_normalize_method_id) {
        return qjsStringNormalize(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == 36) {
        return qjsStringLocaleCompare(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == 4 or method_id == 5 or method_id == 6 or method_id == 7 or method_id == 28) {
        return qjsStringSearchPositionMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame);
    }
    if (method_id == 0 or method_id == 1 or method_id == 25 or method_id == 29 or method_id == 30 or method_id == 31 or method_id == 32 or method_id == 33) {
        return qjsStringNumericArgsMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame);
    }
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    return builtins.string.methodCall(ctx.runtime, string_value, method_id, args) catch |err| switch (err) {
        error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid repeat count"),
        else => err,
    };
}

pub fn qjsStringPad(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);

    var source_units = std.ArrayList(u16).empty;
    defer source_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &source_units, string_value);

    const max_length_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const target_length = try toLengthIndex(ctx, output, global, max_length_value);
    if (target_length <= source_units.items.len) return string_value.dup();

    const fill_value = if (args.len >= 2 and !args[1].isUndefined()) blk: {
        break :blk try toStringForAnnexB(ctx, output, global, args[1], caller_function, caller_frame);
    } else try value_ops.createStringValue(ctx.runtime, " ");
    defer fill_value.free(ctx.runtime);

    var fill_units = std.ArrayList(u16).empty;
    defer fill_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &fill_units, fill_value);
    if (fill_units.items.len == 0) return string_value.dup();

    const fill_length = target_length - source_units.items.len;
    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    if (method_id == 34) {
        try appendRepeatedFillUnits(ctx.runtime, &out, fill_units.items, fill_length);
        try out.appendSlice(ctx.runtime.memory.allocator, source_units.items);
    } else {
        try out.appendSlice(ctx.runtime.memory.allocator, source_units.items);
        try appendRepeatedFillUnits(ctx.runtime, &out, fill_units.items, fill_length);
    }
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn qjsStringNormalize(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);

    const form: unicode_lib.NormalizationForm = if (args.len == 0 or args[0].isUndefined()) .nfc else blk: {
        const form_value = try toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
        defer form_value.free(ctx.runtime);
        var form_bytes = std.ArrayList(u8).empty;
        defer form_bytes.deinit(ctx.runtime.memory.allocator);
        try value_ops.appendRawString(ctx.runtime, &form_bytes, form_value);
        if (std.mem.eql(u8, form_bytes.items, "NFC")) break :blk unicode_lib.NormalizationForm.nfc;
        if (std.mem.eql(u8, form_bytes.items, "NFD")) break :blk unicode_lib.NormalizationForm.nfd;
        if (std.mem.eql(u8, form_bytes.items, "NFKC")) break :blk unicode_lib.NormalizationForm.nfkc;
        if (std.mem.eql(u8, form_bytes.items, "NFKD")) break :blk unicode_lib.NormalizationForm.nfkd;
        return error.RangeError;
    };

    var input = std.ArrayList(u32).empty;
    defer input.deinit(ctx.runtime.memory.allocator);
    try appendUtf32FromStringValue(ctx.runtime, &input, string_value);
    const normalized_slice = try unicode_lib.normalizeAlloc(ctx.runtime.memory.allocator, input.items, form);
    defer ctx.runtime.memory.allocator.free(normalized_slice);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    for (normalized_slice) |code_point| try appendUtf16CodePoint(ctx.runtime, &out, code_point);
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn qjsStringLocaleCompare(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const lhs = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer lhs.free(ctx.runtime);
    const rhs_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const rhs = try toStringForAnnexB(ctx, output, global, rhs_input, caller_function, caller_frame);
    defer rhs.free(ctx.runtime);

    const lhs_nfc = try normalizedUtf32(ctx.runtime, lhs, .nfc);
    defer lhs_nfc.deinit();
    const rhs_nfc = try normalizedUtf32(ctx.runtime, rhs, .nfc);
    defer rhs_nfc.deinit();

    const result: i32 = switch (std.mem.order(u32, lhs_nfc.slice, rhs_nfc.slice)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return core.JSValue.int32(result);
}

pub fn appendUtf32FromStringValue(rt: *core.JSRuntime, out: *std.ArrayList(u32), value: core.JSValue) !void {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.memory.allocator);
    try appendStringValueUnits(rt, &units, value);
    var index: usize = 0;
    while (index < units.items.len) {
        const unit = units.items[index];
        if (isHighSurrogateUnit(unit) and index + 1 < units.items.len and isLowSurrogateUnit(units.items[index + 1])) {
            try out.append(rt.memory.allocator, combinedSurrogateCodePoint(unit, units.items[index + 1]));
            index += 2;
        } else {
            try out.append(rt.memory.allocator, unit);
            index += 1;
        }
    }
}

pub fn appendUtf16CodePoint(rt: *core.JSRuntime, out: *std.ArrayList(u16), code_point: u32) !void {
    if (code_point <= 0xffff) {
        try out.append(rt.memory.allocator, @intCast(code_point));
        return;
    }
    const cp = code_point - 0x10000;
    try out.append(rt.memory.allocator, @intCast(0xd800 + (cp >> 10)));
    try out.append(rt.memory.allocator, @intCast(0xdc00 + (cp & 0x3ff)));
}

pub fn qjsStringNumericArgsMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return throwTypeErrorMessage(ctx, global, "null or undefined are forbidden");
    const string_value = if (this_value.isString())
        this_value
    else
        try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer if (!this_value.isString()) string_value.free(ctx.runtime);

    var coerced: [2]core.JSValue = .{ core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const count = @min(args.len, coerced.len);
    for (args[0..count], 0..) |arg, index| {
        coerced[index] = if (arg.isUndefined())
            core.JSValue.undefinedValue()
        else if (arg.isNumber())
            arg
        else
            try toNumberLikeArgument(ctx, output, global, arg);
    }

    if (method_id == 1) {
        if (try fastLatin1Substring(ctx.runtime, string_value, coerced[0..count])) |value| return value;
    }
    if (method_id == 0) {
        const index = if (count >= 1) coerced[0] else core.JSValue.int32(0);
        return builtins.string.charAtValue(ctx.runtime, string_value, index);
    }
    if (method_id == 25) {
        return qjsStringSubstr(ctx, output, global, string_value, coerced[0..count]);
    }
    return builtins.string.methodCall(ctx.runtime, string_value, method_id, coerced[0..count]) catch |err| switch (err) {
        error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid repeat count"),
        else => err,
    };
}

pub fn fastLatin1Substring(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !?core.JSValue {
    if (!string_value.isString() or args.len > 2) return null;
    const header = string_value.refHeader() orelse return null;
    const string: *core.string.String = @fieldParentPtr("header", header);
    const bytes = switch (string.resolveData()) {
        .latin1 => |latin1| latin1,
        .utf16 => return null,
    };
    const len: i64 = @intCast(string.len());
    const start_raw = if (args.len >= 1) int32OrUndefinedStringIndex(args[0]) orelse return null else 0;
    const end_raw = if (args.len >= 2 and !args[1].isUndefined()) int32OrUndefinedStringIndex(args[1]) orelse return null else len;
    const start: usize = @intCast(@max(@as(i64, 0), @min(start_raw, len)));
    const end: usize = @intCast(@max(@as(i64, 0), @min(end_raw, len)));
    const lo = @min(start, end);
    const hi = @max(start, end);
    if (lo == hi) {
        const empty = try rt.emptyString();
        return empty.value().dup();
    }
    return (try core.string.String.createLatin1(rt, bytes[lo..hi])).value();
}

pub fn int32OrUndefinedStringIndex(value: core.JSValue) ?i64 {
    if (value.isUndefined()) return null;
    return if (value.asInt32()) |int_value| @as(i64, int_value) else null;
}

pub fn qjsStringSubstr(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    string_value: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &units, string_value);

    const size = units.items.len;
    const start_number = if (args.len >= 1 and !args[0].isUndefined())
        value_ops.numberValue(args[0]) orelse std.math.nan(f64)
    else
        0;
    var start: usize = 0;
    if (std.math.isNan(start_number) or start_number == 0) {
        start = 0;
    } else if (start_number < 0) {
        const integer_start = @trunc(start_number);
        if (integer_start == 0) {
            start = 0;
        } else if (std.math.isNegativeInf(integer_start)) {
            start = 0;
        } else {
            const abs_start: usize = @intFromFloat(@min(@abs(integer_start), @as(f64, @floatFromInt(size))));
            start = size - abs_start;
        }
    } else if (std.math.isPositiveInf(start_number)) {
        start = size;
    } else {
        start = @min(@as(usize, @intFromFloat(@trunc(start_number))), size);
    }

    const max_len = size - start;
    const requested_len = if (args.len >= 2 and !args[1].isUndefined()) blk: {
        const length_number = value_ops.numberValue(args[1]) orelse std.math.nan(f64);
        if (std.math.isNan(length_number) or length_number <= 0) break :blk @as(usize, 0);
        if (std.math.isPositiveInf(length_number)) break :blk max_len;
        break :blk @min(@as(usize, @intFromFloat(@trunc(length_number))), max_len);
    } else max_len;

    _ = output;
    _ = global;
    return (try core.string.String.createUtf16(ctx.runtime, units.items[start..][0..requested_len])).value();
}

pub fn qjsStringHtmlMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    var string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);

    var string_units = std.ArrayList(u16).empty;
    defer string_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &string_units, string_value);

    switch (method_id) {
        11 => return qjsStringCreateHtml(ctx, string_units.items, "a", "name", if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), true, output, global, caller_function, caller_frame),
        12 => return qjsStringCreateHtml(ctx, string_units.items, "big", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        13 => return qjsStringCreateHtml(ctx, string_units.items, "blink", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        14 => return qjsStringCreateHtml(ctx, string_units.items, "b", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        15 => return qjsStringCreateHtml(ctx, string_units.items, "tt", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        16 => return qjsStringCreateHtml(ctx, string_units.items, "font", "color", if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), true, output, global, caller_function, caller_frame),
        17 => return qjsStringCreateHtml(ctx, string_units.items, "font", "size", if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), true, output, global, caller_function, caller_frame),
        18 => return qjsStringCreateHtml(ctx, string_units.items, "i", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        19 => return qjsStringCreateHtml(ctx, string_units.items, "a", "href", if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), true, output, global, caller_function, caller_frame),
        20 => return qjsStringCreateHtml(ctx, string_units.items, "small", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        23 => return qjsStringCreateHtml(ctx, string_units.items, "strike", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        24 => return qjsStringCreateHtml(ctx, string_units.items, "sub", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        26 => return qjsStringCreateHtml(ctx, string_units.items, "sup", "", core.JSValue.undefinedValue(), false, output, global, caller_function, caller_frame),
        else => return error.TypeError,
    }
}

pub fn qjsStringCreateHtml(
    ctx: *core.JSContext,
    string_units: []const u16,
    tag: []const u8,
    attr: []const u8,
    attr_value: core.JSValue,
    has_attr: bool,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    try appendAsciiUnits(ctx.runtime, &out, "<");
    try appendAsciiUnits(ctx.runtime, &out, tag);
    if (has_attr) {
        const value = try toStringForAnnexB(ctx, output, global, attr_value, caller_function, caller_frame);
        defer value.free(ctx.runtime);
        var attr_units = std.ArrayList(u16).empty;
        defer attr_units.deinit(ctx.runtime.memory.allocator);
        try appendStringValueUnits(ctx.runtime, &attr_units, value);

        try appendAsciiUnits(ctx.runtime, &out, " ");
        try appendAsciiUnits(ctx.runtime, &out, attr);
        try appendAsciiUnits(ctx.runtime, &out, "=\"");
        for (attr_units.items) |unit| {
            if (unit == '"') {
                try appendAsciiUnits(ctx.runtime, &out, "&quot;");
            } else {
                try out.append(ctx.runtime.memory.allocator, unit);
            }
        }
        try appendAsciiUnits(ctx.runtime, &out, "\"");
    }
    try appendAsciiUnits(ctx.runtime, &out, ">");
    try out.appendSlice(ctx.runtime.memory.allocator, string_units);
    try appendAsciiUnits(ctx.runtime, &out, "</");
    try appendAsciiUnits(ctx.runtime, &out, tag);
    try appendAsciiUnits(ctx.runtime, &out, ">");
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn qjsStringSearchPositionMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);

    const search_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (method_id == 5 or method_id == 6 or method_id == 7) {
        if (try isRegExpForStringSearch(ctx, output, global, search_input, caller_function, caller_frame)) return error.TypeError;
    }
    const search_value = try toStringForAnnexB(ctx, output, global, search_input, caller_function, caller_frame);
    defer search_value.free(ctx.runtime);

    var coerced: [2]core.JSValue = .{ search_value, core.JSValue.undefinedValue() };
    var count: usize = 1;
    if (args.len >= 2) {
        if (args[1].isUndefined()) {
            coerced[1] = core.JSValue.undefinedValue();
        } else {
            const primitive = try toPrimitiveForNumber(ctx, output, global, args[1]);
            defer primitive.free(ctx.runtime);
            if (primitive.isBigInt()) return error.TypeError;
            const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
            defer number_value.free(ctx.runtime);
            coerced[1] = value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
        }
        count = 2;
    }

    return builtins.string.methodCall(ctx.runtime, string_value, method_id, coerced[0..count]);
}

pub fn isRegExpForStringSearch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    return isRegExpObservable(ctx, output, global, value, caller_function, caller_frame);
}

pub fn qjsStringReplaceAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const search_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const replace_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!search_value.isUndefined() and !search_value.isNull() and
        try isRegExpObservable(ctx, output, global, search_value, caller_function, caller_frame))
    {
        const flags_atom = core.atom.predefinedId("flags", .string) orelse return error.TypeError;
        const flags = try getValueProperty(ctx, output, global, search_value, flags_atom, caller_function, caller_frame);
        defer flags.free(ctx.runtime);
        if (flags.isNull() or flags.isUndefined()) return error.TypeError;
        const flags_string = try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
        defer flags_string.free(ctx.runtime);
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(ctx.runtime.memory.allocator);
        try value_ops.appendRawString(ctx.runtime, &bytes, flags_string);
        if (std.mem.indexOfScalar(u8, bytes.items, 'g') == null) return error.TypeError;
    }
    if (try callStringReplaceMethod(ctx, output, global, this_value, search_value, replace_value, caller_function, caller_frame)) |value| return value;

    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    const search_string = try toStringForAnnexB(ctx, output, global, search_value, caller_function, caller_frame);
    defer search_string.free(ctx.runtime);
    const functional_replace = isCallableValue(replace_value);
    const replacement_string = if (functional_replace)
        core.JSValue.undefinedValue()
    else
        try toStringForAnnexB(ctx, output, global, replace_value, caller_function, caller_frame);
    defer if (!functional_replace) replacement_string.free(ctx.runtime);

    return qjsStringReplaceAllStringSearch(ctx, output, global, string_value, search_string, replace_value, replacement_string, functional_replace, caller_function, caller_frame);
}

pub fn qjsStringReplaceAllStringSearch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    string_value: core.JSValue,
    search_string: core.JSValue,
    replace_value: core.JSValue,
    replacement_string: core.JSValue,
    functional_replace: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var source_units = std.ArrayList(u16).empty;
    defer source_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &source_units, string_value);

    var search_units = std.ArrayList(u16).empty;
    defer search_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &search_units, search_string);

    var replacement_units = std.ArrayList(u16).empty;
    defer replacement_units.deinit(ctx.runtime.memory.allocator);
    if (!functional_replace) try appendStringValueUnits(ctx.runtime, &replacement_units, replacement_string);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);

    var end_of_last_match: usize = 0;
    var first = true;
    while (true) {
        const maybe_position = if (search_units.items.len == 0) blk: {
            if (first) break :blk @as(?usize, 0);
            if (end_of_last_match >= source_units.items.len) break :blk null;
            break :blk end_of_last_match + 1;
        } else stringIndexOfUnits(source_units.items, search_units.items, end_of_last_match);

        const position = maybe_position orelse {
            if (first) return string_value.dup();
            break;
        };

        try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[end_of_last_match..position]);
        if (functional_replace) {
            const replacement = try callValueOrBytecode(
                ctx,
                output,
                global,
                core.JSValue.undefinedValue(),
                replace_value,
                &.{ search_string, core.JSValue.int32(@intCast(position)), string_value },
                caller_function,
                caller_frame,
            );
            defer replacement.free(ctx.runtime);
            const replacement_text = try toStringForAnnexB(ctx, output, global, replacement, caller_function, caller_frame);
            defer replacement_text.free(ctx.runtime);
            try appendStringValueUnits(ctx.runtime, &out, replacement_text);
        } else {
            try appendStringReplaceAllSubstitution(ctx.runtime, &out, replacement_units.items, source_units.items, search_units.items, position);
        }

        end_of_last_match = position + search_units.items.len;
        first = false;
    }

    try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[end_of_last_match..]);
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn stringIndexOfUnits(source: []const u16, needle: []const u16, from_index: usize) ?usize {
    if (needle.len == 0) return if (from_index <= source.len) from_index else null;
    if (from_index > source.len or needle.len > source.len - from_index) return null;
    var index = from_index;
    while (index <= source.len - needle.len) : (index += 1) {
        if (std.mem.eql(u16, source[index .. index + needle.len], needle)) return index;
    }
    return null;
}

pub fn appendStringReplaceAllSubstitution(
    rt: *core.JSRuntime,
    out: *std.ArrayList(u16),
    replacement: []const u16,
    source: []const u16,
    matched: []const u16,
    position: usize,
) !void {
    var index: usize = 0;
    while (index < replacement.len) {
        if (replacement[index] != '$' or index + 1 >= replacement.len) {
            try out.append(rt.memory.allocator, replacement[index]);
            index += 1;
            continue;
        }

        const next = replacement[index + 1];
        switch (next) {
            '$' => {
                try out.append(rt.memory.allocator, '$');
                index += 2;
            },
            '&' => {
                try out.appendSlice(rt.memory.allocator, matched);
                index += 2;
            },
            '`' => {
                try out.appendSlice(rt.memory.allocator, source[0..@min(position, source.len)]);
                index += 2;
            },
            '\'' => {
                const tail_start = @min(source.len, position + matched.len);
                try out.appendSlice(rt.memory.allocator, source[tail_start..]);
                index += 2;
            },
            '0'...'9', '<' => {
                try out.append(rt.memory.allocator, '$');
                try out.append(rt.memory.allocator, next);
                index += 2;
            },
            else => {
                try out.append(rt.memory.allocator, '$');
                index += 1;
            },
        }
    }
}

pub fn qjsStringSearch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const regexp = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    if (try callStringWellKnownMethod(ctx, output, global, string_value, regexp, "Symbol.search", caller_function, caller_frame)) |value| return value;
    return try qjsStringRegExpCreateAndInvoke(ctx, output, global, string_value, regexp, "Symbol.search", caller_function, caller_frame);
}

pub fn qjsStringIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    var string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    errdefer string_value.free(ctx.runtime);
    const prototype = try stringIteratorPrototypeFromContext(ctx, global);
    const object = try core.Object.create(ctx.runtime, core.class.ids.string_iterator, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    try object.setOptionalValueSlot(ctx.runtime, object.iteratorTargetSlot(), string_value);
    string_value = core.JSValue.undefinedValue();
    object.iteratorIndexSlot().* = 0;
    return object.value();
}

pub fn stringIteratorPrototypeFromContext(ctx: *core.JSContext, global: *core.Object) !*core.Object {
    const slot: usize = core.class.ids.string_iterator;
    if (slot < ctx.class_prototypes.len) {
        const stored = ctx.class_prototypes[slot];
        if (stored.isObject()) return property_ops.expectObject(stored) catch return error.TypeError;
    }

    const object = try qjsIteratorPrototype(ctx.runtime, global, "String Iterator");
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    try defineNativeDataMethod(ctx.runtime, object, "next", 0);

    const iterator_method = try builtins.function.nativeFunction(ctx.runtime, "[Symbol.iterator]", 0);
    defer iterator_method.free(ctx.runtime);
    const iterator_function = property_ops.expectObject(iterator_method) catch return error.TypeError;
    if (!iterator_function.addIteratorIdentityFunction()) return error.TypeError;
    const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    try object.defineOwnProperty(ctx.runtime, iterator_atom, core.Descriptor.data(iterator_method, true, false, true));

    if (slot < ctx.class_prototypes.len) {
        const value = object.value();
        ctx.class_prototypes[slot] = value.dup();
        value.free(ctx.runtime);
    }
    return object;
}

pub fn qjsStringMatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const regexp = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    if (try callStringWellKnownMethod(ctx, output, global, string_value, regexp, "Symbol.match", caller_function, caller_frame)) |value| return value;
    return try qjsStringRegExpCreateAndInvoke(ctx, output, global, string_value, regexp, "Symbol.match", caller_function, caller_frame);
}

pub fn qjsStringRegExpCreateAndInvoke(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    string_value: core.JSValue,
    regexp: core.JSValue,
    symbol_name: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const regexp_key = try ctx.runtime.internAtom("RegExp");
    defer ctx.runtime.atoms.free(regexp_key);
    const constructor = global.getProperty(regexp_key);
    defer constructor.free(ctx.runtime);
    const rx = try qjsRegExpConstructCall(ctx, output, global, constructor, &.{regexp}, caller_function, caller_frame);
    defer rx.free(ctx.runtime);
    if (try callStringWellKnownMethod(ctx, output, global, string_value, rx, symbol_name, caller_function, caller_frame)) |value| return value;
    if (std.mem.eql(u8, symbol_name, "Symbol.search")) {
        if (try qjsRegExpSearch(ctx.runtime, rx, string_value)) |value| return value;
    } else {
        if (try qjsRegExpMatch(ctx.runtime, global, rx, string_value)) |value| return value;
    }
    return error.TypeError;
}

pub fn callStringWellKnownMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    candidate: core.JSValue,
    symbol_name: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (candidate.isUndefined() or candidate.isNull()) return null;
    if (!candidate.isObject()) return null;
    const symbol_atom = core.atom.predefinedId(symbol_name, .symbol) orelse return error.TypeError;
    const method = try getValueProperty(ctx, output, global, candidate, symbol_atom, caller_function, caller_frame);
    defer method.free(ctx.runtime);
    if (method.isUndefined() or method.isNull()) return null;
    if (!isCallableValue(method)) return error.TypeError;
    const method_args = [_]core.JSValue{this_value};
    return try callValueOrBytecode(ctx, output, global, candidate, method, &method_args, caller_function, caller_frame);
}

pub fn qjsStringSplit(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const separator = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (separator.isObject()) {
        const split_atom = core.atom.predefinedId("Symbol.split", .symbol) orelse return error.TypeError;
        const splitter = try getValueProperty(ctx, output, global, separator, split_atom, caller_function, caller_frame);
        defer splitter.free(ctx.runtime);
        if (!splitter.isUndefined() and !splitter.isNull()) {
            if (!isCallableValue(splitter)) return error.TypeError;
            const split_limit = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            const split_args = [_]core.JSValue{ this_value, split_limit };
            return callValueOrBytecode(ctx, output, global, separator, splitter, &split_args, caller_function, caller_frame);
        }
    }

    const string_value = try toStringForAnnexB(ctx, output, global, this_value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    if (args.len == 0) return qjsStringSplitBuiltinArray(ctx, global, string_value, &.{});

    var coerced: [2]core.JSValue = .{ core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var count: usize = 1;
    var free_separator = false;
    var free_limit = false;
    defer {
        if (free_separator) coerced[0].free(ctx.runtime);
        if (free_limit) coerced[1].free(ctx.runtime);
    }

    if (args.len >= 2 and !args[1].isUndefined()) {
        const primitive = try toPrimitiveForNumber(ctx, output, global, args[1]);
        defer primitive.free(ctx.runtime);
        if (primitive.isBigInt()) return error.TypeError;
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        defer number_value.free(ctx.runtime);
        const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
        coerced[1] = uint32NumberValue(toUint32Number(number));
        free_limit = false;
        count = 2;
    } else if (args.len >= 2) {
        coerced[1] = core.JSValue.undefinedValue();
        count = 2;
    }

    if (try qjsRegExpSplit(ctx.runtime, separator, string_value, coerced[1])) |result| return result;

    if (args[0].isUndefined()) {
        coerced[0] = core.JSValue.undefinedValue();
    } else {
        coerced[0] = try toStringForAnnexB(ctx, output, global, args[0], caller_function, caller_frame);
        free_separator = true;
    }

    return qjsStringSplitBuiltinArray(ctx, global, string_value, coerced[0..count]);
}

pub fn qjsStringSplitBuiltinArray(
    ctx: *core.JSContext,
    global: *core.Object,
    string_value: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    const result = try builtins.string.methodCall(ctx.runtime, string_value, builtins.string.legacy_split_method_id, args);
    errdefer result.free(ctx.runtime);
    if (objectFromValue(result)) |object| {
        if (object.is_array and object.getPrototype() == null) {
            if (arrayPrototypeFromGlobal(ctx.runtime, global)) |prototype| {
                try object.setPrototype(ctx.runtime, prototype);
            }
        }
    }
    return result;
}

pub fn qjsRegExpSplit(rt: *core.JSRuntime, separator: core.JSValue, string_value: core.JSValue, limit_value: core.JSValue) !?core.JSValue {
    const separator_object = property_ops.expectObject(separator) catch return null;
    if (separator_object.class_id != core.class.ids.regexp) return null;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(rt.memory.allocator);
    if (!try appendRegExpSource(rt, separator_object, &source)) return null;

    var flags = std.ArrayList(u8).empty;
    defer flags.deinit(rt.memory.allocator);
    if (!try appendRegExpFlags(rt, separator_object, &flags)) return null;
    // Use sticky flag for split iteration
    var split_flags = std.ArrayList(u8).empty;
    defer split_flags.deinit(rt.memory.allocator);
    try split_flags.appendSlice(rt.memory.allocator, flags.items);
    if (std.mem.indexOfScalar(u8, split_flags.items, 'y') == null) {
        try split_flags.append(rt.memory.allocator, 'y');
    }

    const limit = if (limit_value.isUndefined()) std.math.maxInt(u32) else toUint32Number(value_ops.numberValue(limit_value) orelse std.math.nan(f64));
    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    if (limit == 0) return out.value();

    var compiled = quickjs_regexp.compile(rt.memory.allocator, source.items, split_flags.items) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return null,
        else => |other| return other,
    };
    defer compiled.deinit(rt.memory.allocator);

    const input_len = try stringLengthIndex(rt, string_value);

    if (input_len == 0) {
        const status = quickjs_regexp.execOnStringFromIndex(compiled, string_value, 0) catch |err| switch (err) {
            error.BytecodeCorrupt, error.Timeout => return null,
            else => return err,
        };
        if (status.result == .match) return out.value();
        const slice = try stringSliceValue(rt, string_value, 0, 0);
        defer slice.free(rt);
        try defineSplitValueElement(rt, out, 0, slice);
        return out.value();
    }
    if (std.mem.eql(u8, source.items, "(?:)")) {
        var index: u32 = 0;
        while (index < input_len) : (index += 1) {
            const ch = try stringSliceValue(rt, string_value, index, 1);
            defer ch.free(rt);
            try defineSplitValueElement(rt, out, index, ch);
            if (index + 1 >= limit) return out.value();
        }
        return out.value();
    }

    var start: usize = 0;
    var pos: usize = 0;
    var out_index: u32 = 0;
    while (pos <= input_len) {
        const status = quickjs_regexp.execOnStringFromIndex(compiled, string_value, pos) catch |err| switch (err) {
            error.BytecodeCorrupt, error.Timeout => return null,
            else => return err,
        };
        switch (status.result) {
            .match => {
                const match = status.match;
                const match_len = match.end - match.start;
                if (match_len == 0) {
                    pos += 1;
                    continue;
                }
                const before = try stringSliceValue(rt, string_value, start, pos - start);
                defer before.free(rt);
                try defineSplitValueElement(rt, out, out_index, before);
                out_index += 1;
                if (out_index >= limit) return out.value();
                // Append captures
                var ci: usize = 0;
                while (ci < match.capture_count) : (ci += 1) {
                    const capture = match.captures[ci];
                    if (capture.start) |cs| {
                        const cap_str = try stringSliceValue(rt, string_value, cs, capture.end.? - cs);
                        defer cap_str.free(rt);
                        try defineSplitValueElement(rt, out, out_index, cap_str);
                    } else {
                        try defineSplitValueElement(rt, out, out_index, core.JSValue.undefinedValue());
                    }
                    out_index += 1;
                    if (out_index >= limit) return out.value();
                }
                pos += match_len;
                start = pos;
            },
            .no_match, .out_of_range, .not_available => {
                pos += 1;
            },
        }
    }
    const tail = try stringSliceValue(rt, string_value, start, input_len - start);
    defer tail.free(rt);
    try defineSplitValueElement(rt, out, out_index, tail);
    return out.value();
}

pub fn qjsRegExpSplitWholeString(rt: *core.JSRuntime, string_value: core.JSValue) !core.JSValue {
    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    try defineSplitValueElement(rt, out, 0, string_value);
    return out.value();
}

pub fn qjsRegExpSearch(rt: *core.JSRuntime, regexp: core.JSValue, string_value: core.JSValue) !?core.JSValue {
    const regexp_object = property_ops.expectObject(regexp) catch return null;
    if (regexp_object.class_id != core.class.ids.regexp) return null;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(rt.memory.allocator);
    if (!try appendRegExpSource(rt, regexp_object, &source)) return null;

    var flags = std.ArrayList(u8).empty;
    defer flags.deinit(rt.memory.allocator);
    if (!try appendRegExpFlags(rt, regexp_object, &flags)) return null;

    var compiled = quickjs_regexp.compile(rt.memory.allocator, source.items, flags.items) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return null,
        else => |other| return other,
    };
    defer compiled.deinit(rt.memory.allocator);

    const input_len = try stringLengthIndex(rt, string_value);
    const status = quickjs_regexp.execOnStringFromIndex(compiled, string_value, 0) catch |err| switch (err) {
        error.BytecodeCorrupt, error.Timeout => return null,
        else => return err,
    };
    switch (status.result) {
        .match => {
            if (status.match.start > input_len) return core.JSValue.int32(-1);
            return core.JSValue.int32(@intCast(status.match.start));
        },
        .no_match, .out_of_range => return core.JSValue.int32(-1),
        .not_available => return null,
    }
}

pub fn qjsRegExpMatch(rt: *core.JSRuntime, global: *core.Object, regexp: core.JSValue, string_value: core.JSValue) !?core.JSValue {
    const regexp_object = property_ops.expectObject(regexp) catch return null;
    if (regexp_object.class_id != core.class.ids.regexp) return null;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(rt.memory.allocator);
    if (!try appendRegExpSource(rt, regexp_object, &source)) return null;

    var flags = std.ArrayList(u8).empty;
    defer flags.deinit(rt.memory.allocator);
    if (!try appendRegExpFlags(rt, regexp_object, &flags)) return null;
    const is_global = std.mem.indexOfScalar(u8, flags.items, 'g') != null;
    const has_indices = std.mem.indexOfScalar(u8, flags.items, 'd') != null;

    if (!is_global) {
        // Non-global: single LRE match.
        var compiled = quickjs_regexp.compile(rt.memory.allocator, source.items, flags.items) catch |err| switch (err) {
            error.InvalidPattern, error.Unsupported => return null,
            else => |other| return other,
        };
        defer compiled.deinit(rt.memory.allocator);
        const input_len = try stringLengthIndex(rt, string_value);
        const status = quickjs_regexp.execOnStringFromIndex(compiled, string_value, 0) catch |err| switch (err) {
            error.BytecodeCorrupt, error.Timeout => return null,
            else => return err,
        };
        switch (status.result) {
            .match => {
                if (status.match.start > input_len) return core.JSValue.nullValue();
                var found = RegExpMatch{
                    .index = status.match.start,
                    .len = status.match.end - status.match.start,
                    .capture_count = status.match.capture_count,
                };
                var ci: usize = 0;
                while (ci < status.match.capture_count) : (ci += 1) {
                    const capture = status.match.captures[ci];
                    if (capture.start) |cs| {
                        found.captures[ci] = .{ .start = cs, .len = capture.end.? - cs, .undefined = false, .name = capture.name };
                    } else {
                        found.captures[ci] = .{ .start = 0, .len = 0, .undefined = true, .name = capture.name };
                    }
                }
                return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
            },
            .no_match, .out_of_range, .not_available => return null,
        }
    }

    // Global: iterate through all matches
    var compiled = quickjs_regexp.compile(rt.memory.allocator, source.items, flags.items) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return null,
        else => |other| return other,
    };
    defer compiled.deinit(rt.memory.allocator);
    const input_len = try stringLengthIndex(rt, string_value);

    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    var out_index: u32 = 0;
    var search_pos: usize = 0;
    while (search_pos <= input_len) {
        const status = quickjs_regexp.execOnStringFromIndex(compiled, string_value, search_pos) catch |err| switch (err) {
            error.BytecodeCorrupt, error.Timeout => return null,
            else => return err,
        };
        switch (status.result) {
            .match => {
                const match = status.match;
                if (match.start > input_len) break;
                const match_str = try stringSliceValue(rt, string_value, match.start, match.end - match.start);
                defer match_str.free(rt);
                try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(match_str, true, true, true));
                out_index += 1;
                if (match.end == search_pos) {
                    // Advance past zero-length match
                    search_pos = match.end + 1;
                } else {
                    search_pos = match.end;
                }
            },
            .no_match, .out_of_range, .not_available => break,
        }
    }
    if (out_index == 0) {
        core.Object.destroyFromHeader(rt, &out.header);
        return core.JSValue.nullValue();
    }
    return out.value();
}

pub fn unicodeLowSurrogateLiteralMatch(source: []const u8, value: core.JSValue, start: usize, sticky: bool) ?RegExpMatch {
    const unit = singleLowSurrogateLiteralSource(source) orelse return null;
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    if (start > string_value.len()) return null;
    if (sticky) return lowSurrogateLiteralAt(unit, string_value.*, start);
    var index = start;
    while (index < string_value.len()) {
        if (lowSurrogateLiteralAt(unit, string_value.*, index)) |found| return found;
        index = advanceStringIndexStringValue(string_value.*, index, true);
    }
    return null;
}

pub fn advanceStringIndexStringValue(string_value: core.string.String, index: usize, unicode: bool) usize {
    if (!unicode or index + 1 >= string_value.len()) return index + 1;
    const first = string_value.codeUnitAt(index);
    const second = string_value.codeUnitAt(index + 1);
    return index + if (isHighSurrogateUnit(first) and isLowSurrogateUnit(second)) @as(usize, 2) else 1;
}

pub fn findCharacterClassSourceMatch(value: core.JSValue, source: []const u8, start: usize, sticky: bool) ?RegExpMatch {
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            if (sticky) {
                if (start >= bytes.len or !builtins.regexp.classMatchesUtf16Unit(source, bytes[start])) return null;
                return RegExpMatch{ .index = start, .len = 1 };
            }
            var index = start;
            while (index < bytes.len) : (index += 1) {
                if (!builtins.regexp.classMatchesUtf16Unit(source, bytes[index])) continue;
                return RegExpMatch{ .index = index, .len = 1 };
            }
        },
        .utf16 => |units| {
            if (sticky) {
                if (start >= units.len or !builtins.regexp.classMatchesUtf16Unit(source, units[start])) return null;
                return RegExpMatch{ .index = start, .len = 1 };
            }
            var index = start;
            while (index < units.len) : (index += 1) {
                if (!builtins.regexp.classMatchesUtf16Unit(source, units[index])) continue;
                return RegExpMatch{ .index = index, .len = 1 };
            }
        },
    }
    return null;
}

pub fn findStandaloneCharacterClassMatch(value: core.JSValue, source: []const u8, start: usize, sticky: bool) ?RegExpMatch {
    const class_source = standaloneCharacterClassSource(source) orelse return null;
    return findCharacterClassSourceMatch(value, class_source, start, sticky);
}

pub fn findLeadingAlternationCharacterClassSingleUnitMatch(rt: *core.JSRuntime, value: core.JSValue, source: []const u8, start: usize, sticky: bool) ?RegExpMatch {
    const class_source = leadingAlternationCharacterClassSource(source) orelse return null;
    const input_len = stringLengthIndex(rt, value) catch return null;
    if (input_len != 1) return null;
    return findCharacterClassSourceMatch(value, class_source, start, sticky);
}

pub fn findStringUnitMatch(value: core.JSValue, unit: u16, start: usize) ?usize {
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            if (unit > 0xff) return null;
            var index = start;
            while (index < bytes.len) : (index += 1) {
                if (bytes[index] == @as(u8, @intCast(unit))) return index;
            }
        },
        .utf16 => |units| {
            var index = start;
            while (index < units.len) : (index += 1) {
                if (units[index] == unit) return index;
            }
        },
    }
    return null;
}

pub fn simpleUnicodeLiteralMatch(source: []const u8, value: core.JSValue, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    const pattern = parseSimpleUnicodeLiteralSource(source) orelse return null;
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    if (start > string_value.len()) return null;
    if (sticky) return simpleUnicodeLiteralAt(pattern, string_value.*, start, flags);
    var index = start;
    while (index <= string_value.len()) : (index += 1) {
        if (simpleUnicodeLiteralAt(pattern, string_value.*, index, flags)) |found| return found;
    }
    return null;
}

pub fn simpleClassSequenceMatch(source: []const u8, value: core.JSValue, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    const pattern = parseSimpleClassSequenceSource(source, flags) orelse return null;
    return simpleClassSequenceMatchPattern(pattern, value, start, sticky, flags);
}

pub fn simpleClassSequenceMatchPattern(pattern: SimpleClassSequencePattern, value: core.JSValue, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleClassSequenceMatchLatin1(pattern, bytes, start, sticky, flags),
        .utf16 => |units| simpleClassSequenceMatchUtf16(pattern, units, start, sticky, flags),
    };
}

pub fn simpleClassAlternationMatchPattern(pattern: SimpleClassAlternationPattern, value: core.JSValue, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleClassAlternationMatchLatin1(pattern, bytes, start, sticky, flags),
        .utf16 => |units| simpleClassAlternationMatchUtf16(pattern, units, start, sticky, flags),
    };
}

pub fn simpleCaptureSequenceMatchPattern(pattern: SimpleCaptureSequencePattern, value: core.JSValue, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleCaptureSequenceMatchLatin1(pattern, bytes, start, sticky, flags),
        .utf16 => |units| simpleCaptureSequenceMatchUtf16(pattern, units, start, sticky, flags),
    };
}

pub fn simpleClassSequenceMatchLatin1(pattern: SimpleClassSequencePattern, bytes: []const u8, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    if (start > bytes.len) return null;
    if (sticky) return simpleClassSequenceAtLatin1(pattern, bytes, start, flags);
    var index = start;
    while (index <= bytes.len) : (index += 1) {
        if (simpleClassSequenceAtLatin1(pattern, bytes, index, flags)) |found| return found;
    }
    return null;
}

pub fn simpleClassSequenceMatchUtf16(pattern: SimpleClassSequencePattern, units: []const u16, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    if (start > units.len) return null;
    if (sticky) return simpleClassSequenceAtUtf16(pattern, units, start, flags);
    var index = start;
    while (index <= units.len) : (index += 1) {
        if (simpleClassSequenceAtUtf16(pattern, units, index, flags)) |found| return found;
    }
    return null;
}

pub fn simpleClassAlternationMatchLatin1(pattern: SimpleClassAlternationPattern, bytes: []const u8, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    if (start > bytes.len) return null;
    if (sticky) {
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (simpleClassSequenceAtLatin1(alternative, bytes, start, flags)) |found| return found;
        }
        return null;
    }

    var index = start;
    while (index <= bytes.len) : (index += 1) {
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (simpleClassSequenceAtLatin1(alternative, bytes, index, flags)) |found| return found;
        }
    }
    return null;
}

pub fn simpleClassAlternationMatchUtf16(pattern: SimpleClassAlternationPattern, units: []const u16, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    if (start > units.len) return null;
    if (sticky) {
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (simpleClassSequenceAtUtf16(alternative, units, start, flags)) |found| return found;
        }
        return null;
    }

    var index = start;
    while (index <= units.len) : (index += 1) {
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (simpleClassSequenceAtUtf16(alternative, units, index, flags)) |found| return found;
        }
    }
    return null;
}

pub fn simpleCaptureSequenceMatchLatin1(pattern: SimpleCaptureSequencePattern, bytes: []const u8, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    if (start > bytes.len) return null;
    if (sticky) return simpleCaptureSequenceAtLatin1(pattern, bytes, start, flags);
    var index = start;
    while (index <= bytes.len) : (index += 1) {
        if (simpleCaptureSequenceAtLatin1(pattern, bytes, index, flags)) |found| return found;
    }
    return null;
}

pub fn simpleCaptureSequenceMatchUtf16(pattern: SimpleCaptureSequencePattern, units: []const u16, start: usize, sticky: bool, flags: []const u8) ?RegExpMatch {
    if (start > units.len) return null;
    if (sticky) return simpleCaptureSequenceAtUtf16(pattern, units, start, flags);
    var index = start;
    while (index <= units.len) : (index += 1) {
        if (simpleCaptureSequenceAtUtf16(pattern, units, index, flags)) |found| return found;
    }
    return null;
}

pub fn simpleClassSequenceAtomMatches(atom: SimpleClassSequenceAtom, unit: u16) bool {
    return switch (atom.kind) {
        .literal => atom.literal == unit,
        .class => simpleClassPredicateMatches(atom.class_predicate, atom.class_source, unit),
    };
}

pub fn simpleCaptureSequenceAtomMatches(atom: SimpleCaptureSequenceAtom, unit: u16) bool {
    return switch (atom.kind) {
        .literal => atom.literal == unit,
        .class => simpleClassPredicateMatches(atom.class_predicate, atom.class_source, unit),
    };
}

pub fn simpleClassPredicateMatches(predicate: SimpleClassPredicate, source: []const u8, unit: u16) bool {
    return switch (predicate) {
        .generic => builtins.regexp.classMatchesUtf16Unit(source, unit),
        .ascii_digit, .ascii_decimal => unit >= '0' and unit <= '9',
        .ascii_not_digit => !(unit >= '0' and unit <= '9'),
        .ascii_word => (unit >= '0' and unit <= '9') or
            (unit >= 'A' and unit <= 'Z') or
            unit == '_' or
            (unit >= 'a' and unit <= 'z'),
        .ascii_not_word => !((unit >= '0' and unit <= '9') or
            (unit >= 'A' and unit <= 'Z') or
            unit == '_' or
            (unit >= 'a' and unit <= 'z')),
        .ascii_lower => unit >= 'a' and unit <= 'z',
        .ascii_alpha => (unit >= 'A' and unit <= 'Z') or (unit >= 'a' and unit <= 'z'),
    };
}

pub fn isStringLineStartPosition(string_value: core.string.String, pos: usize, multiline: bool) bool {
    if (pos == 0) return true;
    if (!multiline or pos > string_value.len()) return false;
    return isLineTerminatorUnit(string_value.codeUnitAt(pos - 1));
}

pub fn isStringLineEndPosition(string_value: core.string.String, pos: usize, multiline: bool) bool {
    if (pos == string_value.len()) return true;
    if (!multiline or pos > string_value.len()) return false;
    return isLineTerminatorUnit(string_value.codeUnitAt(pos));
}

pub fn unicodeSurrogatePairClassMatch(source: []const u8, value: core.JSValue, start: usize, sticky: bool, unicode: bool) ?RegExpMatch {
    if (!unicode) return null;
    const pattern = parseSurrogatePairClassSource(source) orelse return null;
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    if (start > string_value.len()) return null;
    if (sticky) return surrogatePairClassAt(pattern, string_value.*, start);
    var index = start;
    while (index + 1 < string_value.len()) : (index += 1) {
        if (surrogatePairClassAt(pattern, string_value.*, index)) |found| return found;
    }
    return null;
}

pub fn unicodeAstralSpecialMatch(source: []const u8, value: core.JSValue, start: usize, sticky: bool, unicode: bool) ?RegExpMatch {
    if (!unicode) return null;
    const pattern = parseUnicodeAstralSpecialSource(source) orelse return null;
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    if (start > string_value.len()) return null;
    if (sticky) return unicodeAstralSpecialAt(pattern, string_value.*, start);
    var index = start;
    while (index < string_value.len()) {
        if (unicodeAstralSpecialAt(pattern, string_value.*, index)) |found| return found;
        const cp = stringCodePointAt(string_value.*, index) orelse break;
        index += cp.len;
    }
    return null;
}

pub fn stringCodePointAt(string_value: core.string.String, pos: usize) ?struct { value: u21, len: usize } {
    if (pos >= string_value.len()) return null;
    const first = string_value.codeUnitAt(pos);
    if (isHighSurrogateUnit(first) and pos + 1 < string_value.len()) {
        const second = string_value.codeUnitAt(pos + 1);
        if (isLowSurrogateUnit(second)) return .{ .value = codePointFromSurrogatePair(first, second), .len = 2 };
    }
    return .{ .value = @intCast(first), .len = 1 };
}

pub fn codePointFromSurrogatePair(high: u16, low: u16) u21 {
    return 0x10000 + ((@as(u21, high) - 0xd800) << 10) + (@as(u21, low) - 0xdc00);
}

pub fn surrogatePairFromCodePoint(code_point: u21) struct { high: u16, low: u16 } {
    const value = code_point - 0x10000;
    return .{
        .high = @intCast(0xd800 + (value >> 10)),
        .low = @intCast(0xdc00 + (value & 0x3ff)),
    };
}

pub fn findUnicodeFoldClassMatch(value: core.JSValue, unit: u16, start: usize) ?usize {
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            var index = start;
            while (index < bytes.len) : (index += 1) {
                if (unicodeSimpleFoldClassMatches(unit, bytes[index])) return index;
            }
        },
        .utf16 => |units| {
            var index = start;
            while (index < units.len) : (index += 1) {
                if (unicodeSimpleFoldClassMatches(unit, units[index])) return index;
            }
        },
    }
    return null;
}

pub fn unicodeSimpleFoldClassMatches(pattern: u16, input: u16) bool {
    if (pattern == input) return true;
    return (pattern == 0x212a and (input == 'K' or input == 'k')) or
        ((pattern == 'K' or pattern == 'k') and input == 0x212a) or
        (pattern == 0x0390 and input == 0x1fd3) or
        (pattern == 0x1fd3 and input == 0x0390) or
        (pattern == 0x03b0 and input == 0x1fe3) or
        (pattern == 0x1fe3 and input == 0x03b0) or
        (pattern == 0xfb05 and input == 0xfb06) or
        (pattern == 0xfb06 and input == 0xfb05);
}

pub fn isStringHighSurrogateAt(value: core.JSValue, index: usize) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isString()) return false;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_value.resolveData()) {
        .latin1 => false,
        .utf16 => |units| index < units.len and isHighSurrogateUnit(units[index]),
    };
}

pub fn singleDotAnchoredMatches(rt: *core.JSRuntime, string_value: core.JSValue, flags: []const u8) !bool {
    _ = rt;
    const header = string_value.refHeader() orelse return false;
    if (!string_value.isString()) return false;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    const dot_all = std.mem.indexOfScalar(u8, flags, 's') != null;
    const unicode = std.mem.indexOfScalar(u8, flags, 'u') != null;
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            if (bytes.len != 1) return false;
            return dot_all or !isRegExpLineTerminator(bytes[0]);
        },
        .utf16 => |units| {
            if (unicode and units.len == 2 and isHighSurrogateUnit(units[0]) and isLowSurrogateUnit(units[1])) return true;
            if (units.len != 1) return false;
            return dot_all or !isRegExpLineTerminator(units[0]);
        },
    }
}

pub fn anchoredWhitespaceMatches(string_value: core.JSValue) bool {
    const header = string_value.refHeader() orelse return false;
    if (!string_value.isString()) return false;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            if (bytes.len == 0) return false;
            for (bytes) |byte| {
                if (!isEcmaWhitespaceOrLineTerminator(byte)) return false;
            }
            return true;
        },
        .utf16 => |units| {
            if (units.len == 0) return false;
            for (units) |unit| {
                if (!isEcmaWhitespaceOrLineTerminator(unit)) return false;
            }
            return true;
        },
    }
}

pub fn anchoredSingleNonWhitespaceMatches(string_value: core.JSValue, unicode: bool) bool {
    const header = string_value.refHeader() orelse return false;
    if (!string_value.isString()) return false;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| return bytes.len == 1 and !isEcmaWhitespaceOrLineTerminator(bytes[0]),
        .utf16 => |units| {
            if (unicode and units.len == 2 and isHighSurrogateUnit(units[0]) and isLowSurrogateUnit(units[1])) return true;
            return units.len == 1 and !isEcmaWhitespaceOrLineTerminator(units[0]);
        },
    }
}

pub fn isSimpleStringClassEscapeSource(source: []const u8) bool {
    const kind_index = classEscapeKindIndex(source) orelse return false;
    const kind = source[kind_index];
    if (std.mem.indexOfScalar(u8, "dDsSwW", kind) == null) return false;
    return source.len == kind_index + 1 or
        (source.len == kind_index + 2 and source[kind_index + 1] == '+');
}

pub fn findStringClassEscapeMatch(string_value: core.JSValue, source: []const u8, start: usize) ?RegExpMatch {
    const header = string_value.refHeader() orelse return null;
    if (!string_value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            var index = start;
            while (index < bytes.len) : (index += 1) {
                if (!classEscapeUnitMatches(source, bytes[index])) continue;
                const len = classEscapeRunLengthLatin1(source, bytes, index);
                return RegExpMatch{ .index = index, .len = len };
            }
        },
        .utf16 => |units| {
            var index = start;
            while (index < units.len) : (index += 1) {
                if (!classEscapeUnitMatches(source, units[index])) continue;
                const len = classEscapeRunLengthUtf16(source, units, index);
                return RegExpMatch{ .index = index, .len = len };
            }
        },
    }
    return null;
}

pub fn classEscapeUnitMatches(source: []const u8, unit: u16) bool {
    const kind_index = classEscapeKindIndex(source) orelse return false;
    return switch (source[kind_index]) {
        'd' => isAsciiDigitUnit(unit),
        'D' => !isAsciiDigitUnit(unit),
        's' => isEcmaWhitespaceOrLineTerminator(unit),
        'S' => !isEcmaWhitespaceOrLineTerminator(unit),
        'w' => isAsciiWordUnit(unit),
        'W' => !isAsciiWordUnit(unit),
        else => false,
    };
}

pub fn anchoredComplementClassMatches(source: []const u8, string_value: core.JSValue) bool {
    const header = string_value.refHeader() orelse return false;
    if (!string_value.isString()) return false;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            if (bytes.len == 0) return false;
            for (bytes) |byte| {
                if (!complementClassUnitMatches(source, byte)) return false;
            }
            return true;
        },
        .utf16 => |units| {
            if (units.len == 0) return false;
            for (units) |unit| {
                if (!complementClassUnitMatches(source, unit)) return false;
            }
            return true;
        },
    }
}

pub fn anchoredBinaryPropertyMatches(source: []const u8, string_value: core.JSValue) bool {
    const header = string_value.refHeader() orelse return false;
    if (!string_value.isString()) return false;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    const name = anchoredBinaryPropertyName(source) orelse return false;
    const positive = std.mem.startsWith(u8, source, "^\\p{");
    return anchoredCodePointPredicateMatches(string_object, positive, name);
}

pub fn binaryPropertyCodePointMatches(name: []const u8, code_point: u21) bool {
    return shared_vm.regexp_unicode.isUnicodePropertyMatches(code_point, name);
}

pub fn anchoredCodePointPredicateMatches(
    string_object: *core.string.String,
    positive: bool,
    name: []const u8,
) bool {
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            if (bytes.len == 0) return false;
            for (bytes) |byte| {
                if (shared_vm.regexp_unicode.isUnicodePropertyMatches(byte, name) != positive) return false;
            }
            return true;
        },
        .utf16 => |units| {
            if (units.len == 0) return false;
            var index: usize = 0;
            while (index < units.len) {
                if (shared_vm.regexp_unicode.isUnicodePropertyMatches(readUtf16CodePoint(units, &index), name) != positive) return false;
            }
            return true;
        },
    }
}

pub fn readUtf16CodePoint(units: []const u16, index: *usize) u21 {
    const high = units[index.*];
    if (high >= 0xd800 and high <= 0xdbff and index.* + 1 < units.len) {
        const low = units[index.* + 1];
        if (low >= 0xdc00 and low <= 0xdfff) {
            index.* += 2;
            return @intCast(0x10000 + ((@as(u32, high) - 0xd800) << 10) + (@as(u32, low) - 0xdc00));
        }
    }
    index.* += 1;
    return @intCast(high);
}
pub fn complementClassUnitMatches(source: []const u8, unit: u16) bool {
    if (std.mem.eql(u8, source, "^\\D+$")) return !isAsciiDigitUnit(unit);
    if (std.mem.eql(u8, source, "^\\W+$")) return !isAsciiWordUnit(unit);
    if (std.mem.eql(u8, source, "^\\S+$")) return !isEcmaWhitespaceOrLineTerminator(unit);
    return false;
}

pub const RegExpMatch = struct {
    index: usize,
    len: usize,
    captures: [256]RegExpCapture = undefined,
    capture_count: usize = 0,
};

pub fn defineSplitStringElement(rt: *core.JSRuntime, object: *core.Object, index: u32, bytes: []const u8) !void {
    const value = value_ops.createStringValue(rt, bytes) catch |err| switch (err) {
        error.InvalidUtf8 => try createStringFromByteUnits(rt, bytes),
        else => return err,
    };
    defer value.free(rt);
    try defineSplitValueElement(rt, object, index, value);
}

pub fn defineSplitUnitsElement(rt: *core.JSRuntime, object: *core.Object, index: u32, units: []const u16) !void {
    const value = (try core.string.String.createUtf16(rt, units)).value();
    defer value.free(rt);
    try defineSplitValueElement(rt, object, index, value);
}

pub fn createStringFromByteUnits(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    var units = std.ArrayList(u16).empty;
    defer units.deinit(rt.memory.allocator);
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        if (index + 1 < bytes.len and bytes[index] == 0xd8 and bytes[index + 1] == 0xdf) {
            try units.append(rt.memory.allocator, 0xd834);
            try units.append(rt.memory.allocator, 0xdf06);
            index += 1;
            continue;
        }
        if (bytes[index] == 0xd8) {
            try units.append(rt.memory.allocator, 0xd834);
            continue;
        }
        if (bytes[index] == 0xdf) {
            try units.append(rt.memory.allocator, 0xdf06);
            continue;
        }
        try units.append(rt.memory.allocator, bytes[index]);
    }
    return (try core.string.String.createUtf16(rt, units.items)).value();
}

pub fn defineSplitValueElement(rt: *core.JSRuntime, object: *core.Object, index: u32, value: core.JSValue) !void {
    const atom_id = core.atom.atomFromUInt32(index);
    if (try object.appendDenseArrayIndex(rt, index, atom_id, value)) return;
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true));
}

pub fn regExpMatchHasNamedCaptures(found: RegExpMatch) bool {
    for (found.captures[0..found.capture_count]) |capture| {
        if (capture.name != null) return true;
    }
    return false;
}

pub fn createRegExpMatchArray(rt: *core.JSRuntime, global: *core.Object, input_bytes: []const u8, found: RegExpMatch, has_indices: bool) !core.JSValue {
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    try defineSplitStringElement(rt, out, 0, input_bytes[found.index .. found.index + found.len]);
    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const capture = found.captures[capture_index];
        if (capture.undefined) {
            try defineSplitValueElement(rt, out, @intCast(capture_index + 1), core.JSValue.undefinedValue());
        } else {
            try defineSplitStringElement(rt, out, @intCast(capture_index + 1), input_bytes[capture.start .. capture.start + capture.len]);
        }
    }
    const input = value_ops.createStringValue(rt, input_bytes) catch |err| switch (err) {
        error.InvalidUtf8 => try createStringFromByteUnits(rt, input_bytes),
        else => return err,
    };
    defer input.free(rt);
    if (!has_indices and !regExpMatchHasNamedCaptures(found)) {
        try out.defineRegExpMatchMetadataPropertiesAssumingNew(rt, @intCast(found.index), input, core.JSValue.undefinedValue());
    } else {
        try defineFreshNonIndexDataProperty(rt, out, core.atom.predefinedId("index", .string).?, core.JSValue.int32(@intCast(found.index)), true, true, true);
        try defineFreshNonIndexDataProperty(rt, out, core.atom.predefinedId("input", .string).?, input, true, true, true);
        try defineRegExpGroupsProperty(rt, out, input_bytes, found);
    }
    if (has_indices) {
        const indices = try createRegExpIndicesArray(rt, global, input_bytes, found);
        defer indices.free(rt);
        const indices_atom = core.atom.predefinedId("indices", .string) orelse return error.TypeError;
        try defineFreshNonIndexDataProperty(rt, out, indices_atom, indices, true, true, true);
    }
    return out.value();
}

pub fn createRegExpMatchArrayFromValue(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: RegExpMatch, has_indices: bool) !core.JSValue {
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &out.header);

    const matched = try stringSliceValue(rt, input_value, found.index, found.len);
    defer matched.free(rt);

    var legacy_capture_values: [9]?core.JSValue = @splat(null);
    var last_capture_value: ?core.JSValue = null;
    defer {
        for (&legacy_capture_values) |*value_slot| {
            if (value_slot.*) |value| value.free(rt);
        }
        if (last_capture_value) |value| value.free(rt);
    }
    try initRegExpMatchArrayDenseElementsFromValue(rt, out, input_value, found, matched, &legacy_capture_values, &last_capture_value);

    try updateRegExpLegacyStaticsForMatchValues(rt, global, input_value, found, matched, &legacy_capture_values, last_capture_value);

    if (!has_indices and !regExpMatchHasNamedCaptures(found)) {
        try out.defineRegExpMatchMetadataPropertiesAssumingNew(rt, @intCast(found.index), input_value, core.JSValue.undefinedValue());
    } else {
        try defineFreshNonIndexDataProperty(rt, out, core.atom.predefinedId("index", .string).?, core.JSValue.int32(@intCast(found.index)), true, true, true);
        try defineFreshNonIndexDataProperty(rt, out, core.atom.predefinedId("input", .string).?, input_value, true, true, true);
        try defineRegExpGroupsPropertyFromValue(rt, out, input_value, found);
    }
    if (has_indices) {
        const indices = try createRegExpIndicesArray(rt, global, &.{}, found);
        defer indices.free(rt);
        const indices_atom = core.atom.predefinedId("indices", .string) orelse return error.TypeError;
        try defineFreshNonIndexDataProperty(rt, out, indices_atom, indices, true, true, true);
    }
    return out.value();
}

pub fn initRegExpMatchArrayDenseElementsFromValue(
    rt: *core.JSRuntime,
    out: *core.Object,
    input_value: core.JSValue,
    found: RegExpMatch,
    matched: core.JSValue,
    legacy_capture_values: *[9]?core.JSValue,
    last_capture_value: *?core.JSValue,
) !void {
    std.debug.assert(out.is_array);
    std.debug.assert(out.length == 0);
    std.debug.assert(out.arrayElements().len == 0);
    std.debug.assert(out.arrayElementsCapacity() == 0);

    const element_count = found.capture_count + 1;
    const elements = try rt.memory.alloc(?core.JSValue, element_count);
    var initialized: usize = 0;
    errdefer {
        for (elements[0..initialized]) |slot| {
            if (slot) |value| value.free(rt);
        }
        rt.memory.free(?core.JSValue, elements);
    }

    elements[0] = matched.dup();
    initialized = 1;

    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const element_index = capture_index + 1;
        const capture = found.captures[capture_index];
        if (capture.undefined) {
            elements[element_index] = core.JSValue.undefinedValue();
        } else {
            const capture_value = try stringSliceValue(rt, input_value, capture.start, capture.len);
            defer capture_value.free(rt);
            if (capture_index < legacy_capture_values.len) legacy_capture_values[capture_index] = capture_value.dup();
            const next_last_capture = capture_value.dup();
            const old_last_capture = last_capture_value.*;
            last_capture_value.* = next_last_capture;
            if (old_last_capture) |old| old.free(rt);
            elements[element_index] = capture_value.dup();
        }
        initialized += 1;
    }

    out.arrayElementsSlot().* = elements[0..element_count];
    out.arrayElementsCapacitySlot().* = element_count;
    out.may_have_indexed_properties = true;
    out.length = @intCast(element_count);
}

pub fn createRegExpMatchArrayNoCapturesFromValue(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: RegExpMatch, input_len: usize, has_indices: bool) !core.JSValue {
    std.debug.assert(found.capture_count == 0);
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &out.header);

    const matched = try stringSliceValue(rt, input_value, found.index, found.len);
    defer matched.free(rt);
    try out.initDenseArrayIndexZeroAssumingEmpty(rt, matched);

    try updateRegExpLegacyStaticsNoCaptures(rt, global, input_value, found, input_len);

    if (!has_indices) {
        try out.defineRegExpMatchMetadataPropertiesAssumingNew(rt, @intCast(found.index), input_value, core.JSValue.undefinedValue());
    } else {
        try defineFreshNonIndexDataProperty(rt, out, core.atom.predefinedId("index", .string).?, core.JSValue.int32(@intCast(found.index)), true, true, true);
        try defineFreshNonIndexDataProperty(rt, out, core.atom.predefinedId("input", .string).?, input_value, true, true, true);
        const groups_atom = core.atom.predefinedId("groups", .string) orelse return error.TypeError;
        try defineFreshNonIndexDataProperty(rt, out, groups_atom, core.JSValue.undefinedValue(), true, true, true);
    }
    if (has_indices) {
        const indices = try createRegExpIndicesArray(rt, global, &.{}, found);
        defer indices.free(rt);
        const indices_atom = core.atom.predefinedId("indices", .string) orelse return error.TypeError;
        try defineFreshNonIndexDataProperty(rt, out, indices_atom, indices, true, true, true);
    }
    return out.value();
}

pub fn updateRegExpLegacyStaticsForMatchValues(
    rt: *core.JSRuntime,
    global: *core.Object,
    input_value: core.JSValue,
    found: RegExpMatch,
    matched: core.JSValue,
    legacy_capture_values: *const [9]?core.JSValue,
    last_capture_value: ?core.JSValue,
) !void {
    const regexp_ctor = regExpConstructorFromGlobal(rt, global) catch return;
    if (regexp_ctor.class_payload_kind != .function) return;
    const legacy = try regexp_ctor.ensureRegExpLegacyStatics(rt);
    legacy.lazy_no_capture_match = false;

    try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.input, input_value);
    try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.last_match, matched);

    if (found.index == 0) {
        clearRegExpLegacySlot(rt, &legacy.left_context);
    } else {
        const left = try stringSliceValue(rt, input_value, 0, found.index);
        defer left.free(rt);
        try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.left_context, left);
    }

    const input_len = try stringLengthIndex(rt, input_value);
    const right_start = @min(found.index + found.len, input_len);
    if (right_start >= input_len) {
        clearRegExpLegacySlot(rt, &legacy.right_context);
    } else {
        const right = try stringSliceValue(rt, input_value, right_start, input_len - right_start);
        defer right.free(rt);
        try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.right_context, right);
    }

    if (last_capture_value) |value| {
        try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.last_paren, value);
    } else {
        clearRegExpLegacySlot(rt, &legacy.last_paren);
    }

    var slot_index: usize = 0;
    while (slot_index < legacy.captures.len) : (slot_index += 1) {
        if (slot_index < found.capture_count) {
            if (legacy_capture_values[slot_index]) |value| {
                try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.captures[slot_index], value);
                continue;
            }
        }
        clearRegExpLegacySlot(rt, &legacy.captures[slot_index]);
    }
}

pub fn updateRegExpLegacyStaticsForMatch(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: RegExpMatch) !void {
    const matched = try stringSliceValue(rt, input_value, found.index, found.len);
    defer matched.free(rt);

    var legacy_capture_values: [9]?core.JSValue = @splat(null);
    var last_capture_value: ?core.JSValue = null;
    defer {
        for (&legacy_capture_values) |*value_slot| {
            if (value_slot.*) |value| value.free(rt);
        }
        if (last_capture_value) |value| value.free(rt);
    }
    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const capture = found.captures[capture_index];
        if (capture.undefined) continue;
        const value = try stringSliceValue(rt, input_value, capture.start, capture.len);
        defer value.free(rt);
        if (capture_index < legacy_capture_values.len) legacy_capture_values[capture_index] = value.dup();
        const next_last_capture = value.dup();
        if (last_capture_value) |old| old.free(rt);
        last_capture_value = next_last_capture;
    }

    try updateRegExpLegacyStaticsForMatchValues(rt, global, input_value, found, matched, &legacy_capture_values, last_capture_value);
}

pub fn createStartOfLineUnicodeMatchArray(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue) !core.JSValue {
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &out.header);

    try defineSplitValueElement(rt, out, 0, input_value);
    const capture = try value_ops.createStringValue(rt, "f");
    defer capture.free(rt);
    try defineSplitValueElement(rt, out, 1, capture);
    try out.defineOwnProperty(rt, core.atom.predefinedId("index", .string).?, core.Descriptor.data(core.JSValue.int32(0), true, true, true));
    try out.defineOwnProperty(rt, core.atom.predefinedId("input", .string).?, core.Descriptor.data(input_value, true, true, true));
    const groups_atom = core.atom.predefinedId("groups", .string) orelse return error.TypeError;
    try out.defineOwnProperty(rt, groups_atom, core.Descriptor.data(core.JSValue.undefinedValue(), true, true, true));
    return out.value();
}

pub fn appendUtf8CodePointForRegExpName(rt: *core.JSRuntime, out: *std.ArrayList(u8), cp: u21) !void {
    if (cp <= 0x7f) {
        try out.append(rt.memory.allocator, @intCast(cp));
    } else if (cp <= 0x7ff) {
        try out.append(rt.memory.allocator, @intCast(0xc0 | (cp >> 6)));
        try out.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    } else if (cp <= 0xffff) {
        try out.append(rt.memory.allocator, @intCast(0xe0 | (cp >> 12)));
        try out.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try out.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    } else {
        try out.append(rt.memory.allocator, @intCast(0xf0 | (cp >> 18)));
        try out.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 12) & 0x3f)));
        try out.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try out.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    }
}

pub fn isHighSurrogateCodePoint(cp: u21) bool {
    return cp >= 0xd800 and cp <= 0xdbff;
}

pub fn isLowSurrogateCodePoint(cp: u21) bool {
    return cp >= 0xdc00 and cp <= 0xdfff;
}

pub fn combinedSurrogateCodePoint(high: u16, low: u16) u21 {
    return 0x10000 + ((@as(u21, high) - 0xd800) << 10) + (@as(u21, low) - 0xdc00);
}

pub fn createRegExpMatchArrayFromStringValue(rt: *core.JSRuntime, input_value: core.JSValue, found: RegExpMatch) !core.JSValue {
    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    try defineSplitValueElement(rt, out, 0, input_value);
    try out.defineOwnProperty(rt, core.atom.predefinedId("index", .string).?, core.Descriptor.data(core.JSValue.int32(@intCast(found.index)), true, true, true));
    try out.defineOwnProperty(rt, core.atom.predefinedId("input", .string).?, core.Descriptor.data(input_value, true, true, true));
    return out.value();
}

pub fn createRegExpMatchArrayFromStringSliceValue(rt: *core.JSRuntime, input_value: core.JSValue, start: usize, len: usize) !core.JSValue {
    const out = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    const match_value = try stringSliceValue(rt, input_value, start, len);
    defer match_value.free(rt);
    try defineSplitValueElement(rt, out, 0, match_value);
    try out.defineOwnProperty(rt, core.atom.predefinedId("index", .string).?, core.Descriptor.data(core.JSValue.int32(@intCast(start)), true, true, true));
    try out.defineOwnProperty(rt, core.atom.predefinedId("input", .string).?, core.Descriptor.data(input_value, true, true, true));
    return out.value();
}

pub fn stringSliceValue(rt: *core.JSRuntime, value: core.JSValue, start: usize, len: usize) !core.JSValue {
    const header = value.refHeader() orelse return value.dup();
    if (!value.isString()) return value.dup();
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    const input_len = string_value.len();
    const slice_start = @min(start, input_len);
    const slice_end = @min(input_len, slice_start + len);
    const slice_len = slice_end - slice_start;
    if (slice_start == 0 and slice_len == input_len) return value.dup();
    if (slice_len == 0) return (try rt.emptyString()).value().dup();
    if (slice_len == 1) {
        const unit = string_value.codeUnitAt(slice_start);
        if (unit <= 0x7f) {
            const cached = (try rt.singleByteString(@intCast(unit))) orelse unreachable;
            return cached.value().dup();
        }
    }
    return (try core.string.String.createSlice(rt, string_value, slice_start, slice_len)).value();
}

pub fn getStringPrototypeMethodId(rt: *core.JSRuntime, function_object: *core.Object) ?u32 {
    _ = rt;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
    if (native_ref.domain != .string) return null;
    return builtins.string.decodePrototypeMethodId(native_ref.id);
}

pub fn qjsBigIntPrototypeToString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    primitive: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = caller_function;
    _ = caller_frame;
    const radix: u8 = if (args.len == 0 or args[0].isUndefined())
        10
    else blk: {
        const radix_primitive = try toPrimitiveForNumber(ctx, output, global, args[0]);
        defer radix_primitive.free(ctx.runtime);
        if (radix_primitive.isBigInt() or radix_primitive.isSymbol()) return error.TypeError;
        const radix_value = try value_ops.toNumberValue(ctx.runtime, radix_primitive);
        defer radix_value.free(ctx.runtime);
        const radix_number = value_ops.numberValue(radix_value) orelse return error.RangeError;
        if (std.math.isNan(radix_number) or !std.math.isFinite(radix_number)) return error.RangeError;
        const integer = @trunc(radix_number);
        if (integer < 2 or integer > 36) return error.RangeError;
        break :blk @intFromFloat(integer);
    };
    var bigint = try value_ops.cloneBigIntValue(ctx.runtime, primitive);
    defer bigint.deinit();
    const text = try bigint.formatBaseAlloc(ctx.runtime.memory.allocator, radix);
    defer ctx.runtime.memory.allocator.free(text);
    return value_ops.createStringValue(ctx.runtime, text);
}

pub fn standardStringMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "substring")) return 1;
    if (std.mem.eql(u8, name, "toUpperCase")) return 2;
    if (std.mem.eql(u8, name, "toLocaleUpperCase")) return 2;
    if (std.mem.eql(u8, name, "toLowerCase")) return 3;
    if (std.mem.eql(u8, name, "toLocaleLowerCase")) return 3;
    if (std.mem.eql(u8, name, "indexOf")) return 4;
    if (std.mem.eql(u8, name, "includes")) return 5;
    if (std.mem.eql(u8, name, "startsWith")) return 6;
    if (std.mem.eql(u8, name, "endsWith")) return 7;
    if (std.mem.eql(u8, name, "trim")) return 8;
    if (std.mem.eql(u8, name, "lastIndexOf")) return 28;
    if (std.mem.eql(u8, name, "charCodeAt")) return 29;
    if (std.mem.eql(u8, name, "at")) return 30;
    if (std.mem.eql(u8, name, "codePointAt")) return 31;
    if (std.mem.eql(u8, name, "slice")) return 32;
    if (std.mem.eql(u8, name, "repeat")) return 33;
    if (std.mem.eql(u8, name, "padStart")) return 34;
    if (std.mem.eql(u8, name, "padEnd")) return 35;
    if (std.mem.eql(u8, name, "localeCompare")) return 36;
    if (std.mem.eql(u8, name, "normalize")) return builtins.string.legacy_normalize_method_id;
    if (std.mem.eql(u8, name, "isWellFormed")) return 38;
    if (std.mem.eql(u8, name, "toWellFormed")) return 39;
    if (std.mem.eql(u8, name, "search")) return builtins.string.legacy_search_method_id;
    if (std.mem.eql(u8, name, "match")) return builtins.string.legacy_match_method_id;
    if (std.mem.eql(u8, name, "replaceAll")) return builtins.string.legacy_replace_all_method_id;
    if (std.mem.eql(u8, name, "matchAll")) return builtins.string.legacy_match_all_method_id;
    return null;
}

pub fn primitiveStringMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return 9;
    if (std.mem.eql(u8, name, "concat")) return 10;
    if (standardStringMethodId(name)) |method_id| {
        if (method_id == builtins.string.legacy_match_all_method_id) return null;
        return method_id;
    }
    return annexBStringMethodId(name);
}

pub fn genericTrimStringMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "trim")) return 8;
    if (std.mem.eql(u8, name, "trimStart")) return 21;
    if (std.mem.eql(u8, name, "trimEnd")) return 22;
    if (std.mem.eql(u8, name, "trimLeft")) return 21;
    if (std.mem.eql(u8, name, "trimRight")) return 22;
    return null;
}

pub fn isStringMethodReceiver(value: core.JSValue) bool {
    if (value.isString()) return true;
    if (!value.isObject()) return !value.isNull() and !value.isUndefined();
    const object = objectFromValue(value) orelse return false;
    return object.class_id == core.class.ids.string;
}

pub fn annexBStringMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "anchor")) return 11;
    if (std.mem.eql(u8, name, "big")) return 12;
    if (std.mem.eql(u8, name, "blink")) return 13;
    if (std.mem.eql(u8, name, "bold")) return 14;
    if (std.mem.eql(u8, name, "fixed")) return 15;
    if (std.mem.eql(u8, name, "fontcolor")) return 16;
    if (std.mem.eql(u8, name, "fontsize")) return 17;
    if (std.mem.eql(u8, name, "italics")) return 18;
    if (std.mem.eql(u8, name, "link")) return 19;
    if (std.mem.eql(u8, name, "small")) return 20;
    if (std.mem.eql(u8, name, "trimLeft")) return 21;
    if (std.mem.eql(u8, name, "trimStart")) return 21;
    if (std.mem.eql(u8, name, "trimRight")) return 22;
    if (std.mem.eql(u8, name, "trimEnd")) return 22;
    if (std.mem.eql(u8, name, "strike")) return 23;
    if (std.mem.eql(u8, name, "sub")) return 24;
    if (std.mem.eql(u8, name, "substr")) return 25;
    if (std.mem.eql(u8, name, "sup")) return 26;
    if (std.mem.eql(u8, name, "split")) return builtins.string.legacy_split_method_id;
    return null;
}

pub fn qjsFunctionToStringCall(
    ctx: *core.JSContext,
    this_value: core.JSValue,
) !core.JSValue {
    return try call_mod.functionToStringValue(ctx.runtime, this_value);
}

pub fn qjsErrorToStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = objectFromValue(this_value) orelse return error.TypeError;

    const name_value = try getValueProperty(ctx, output, global, this_value, core.atom.ids.name, caller_function, caller_frame);
    defer name_value.free(ctx.runtime);
    const name_string = if (name_value.isUndefined())
        try value_ops.createStringValue(ctx.runtime, "Error")
    else
        try toStringForAnnexB(ctx, output, global, name_value, caller_function, caller_frame);
    defer name_string.free(ctx.runtime);

    const message_atom = core.atom.predefinedId("message", .string).?;
    const message_value = try getValueProperty(ctx, output, global, this_value, message_atom, caller_function, caller_frame);
    defer message_value.free(ctx.runtime);
    const message_string = if (message_value.isUndefined())
        try value_ops.createStringValue(ctx.runtime, "")
    else
        try toStringForAnnexB(ctx, output, global, message_value, caller_function, caller_frame);
    defer message_string.free(ctx.runtime);

    var name_bytes = std.ArrayList(u8).empty;
    defer name_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &name_bytes, name_string);
    var message_bytes = std.ArrayList(u8).empty;
    defer message_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &message_bytes, message_string);

    if (name_bytes.items.len == 0) return try value_ops.createStringValue(ctx.runtime, message_bytes.items);
    if (message_bytes.items.len == 0) return try value_ops.createStringValue(ctx.runtime, name_bytes.items);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    try out.appendSlice(ctx.runtime.memory.allocator, name_bytes.items);
    try out.appendSlice(ctx.runtime.memory.allocator, ": ");
    try out.appendSlice(ctx.runtime.memory.allocator, message_bytes.items);
    return try value_ops.createStringValue(ctx.runtime, out.items);
}

pub fn toStringBytesForSymbol(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) ![]u8 {
    if (value.isSymbol()) return error.TypeError;
    const string_value = if (value.isString())
        value.dup()
    else
        try toStringForAnnexB(ctx, output, global, value, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &buffer, string_value);
    return buffer.toOwnedSlice(ctx.runtime.memory.allocator);
}

pub fn consumePendingExceptionIfMatchesConstructor(ctx: *core.JSContext, expected_name: []const u8) !bool {
    const thrown_value = ctx.exception_slot.value;
    const matches = try thrownValueMatchesConstructor(ctx.runtime, thrown_value, expected_name);
    ctx.clearException();
    return matches;
}

pub fn thrownValueMatchesConstructor(rt: *core.JSRuntime, thrown_value: core.JSValue, expected_name: []const u8) !bool {
    if (!thrown_value.isObject()) return false;
    const thrown_object = property_ops.expectObject(thrown_value) catch return false;
    const ctor_value = thrown_object.getProperty(core.atom.ids.constructor);
    defer ctor_value.free(rt);
    if (ctor_value.isObject()) {
        const ctor = property_ops.expectObject(ctor_value) catch null;
        if (ctor) |ctor_object| {
            const name = try call_mod.nativeFunctionNameForVm(rt, ctor_object);
            defer rt.memory.allocator.free(name);
            if (std.mem.eql(u8, name, expected_name)) return true;
        }
    }
    const name_value = thrown_object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    if (!name_value.isString()) return false;
    var name_bytes = std.ArrayList(u8).empty;
    defer name_bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &name_bytes, name_value);
    return std.mem.eql(u8, name_bytes.items, expected_name);
}

pub fn qjsArraySearchCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    const mode: enum { index_of, last_index_of, includes } = if (arrayPrototypeRecordId(function_object)) |record_id|
        switch (record_id) {
            @intFromEnum(builtins.array.PrototypeMethod.last_index_of) => .last_index_of,
            @intFromEnum(builtins.array.PrototypeMethod.index_of) => .index_of,
            @intFromEnum(builtins.array.PrototypeMethod.includes) => .includes,
            else => return null,
        }
    else blk: {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        break :blk if (std.mem.eql(u8, name, "lastIndexOf"))
            .last_index_of
        else if (std.mem.eql(u8, name, "indexOf"))
            .index_of
        else if (std.mem.eql(u8, name, "includes"))
            .includes
        else
            return null;
    };

    if (receiver.isNull() or receiver.isUndefined()) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    }
    const receiver_object_value = if (objectFromValue(receiver)) |_| receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);
    const object = objectFromValue(receiver_object_value) orelse return null;
    const is_typed_array = builtins.buffer.isTypedArrayObject(object);
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    if (is_typed_method and !is_typed_array) return error.TypeError;
    const array_proto = arrayPrototypeFromGlobal(ctx.runtime, global) orelse return null;
    if (arrayPrototypeRecordId(function_object) == null) {
        const name = switch (mode) {
            .index_of => "indexOf",
            .last_index_of => "lastIndexOf",
            .includes => "includes",
        };
        const method_atom = try ctx.runtime.internAtom(name);
        defer ctx.runtime.atoms.free(method_atom);
        const array_method = array_proto.getProperty(method_atom);
        defer array_method.free(ctx.runtime);
        if (objectFromValue(array_method) != function_object and !is_typed_array) return null;
    }
    const length = if (is_typed_array)
        try arrayMethodTypedArrayLength(ctx.runtime, object, is_typed_method)
    else if (object.is_array)
        @as(usize, @intCast(object.length))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    if (length == 0) return if (mode == .includes) core.JSValue.boolean(false) else core.JSValue.int32(-1);

    const search_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (mode == .last_index_of and length > 1_000_000) {
        return try qjsArrayLastIndexSparseLarge(ctx, output, global, object, receiver_object_value, args, length, search_value);
    }
    if (mode == .last_index_of) {
        var cursor = try arrayLastIndexStart(ctx, output, global, args, length);
        while (cursor > 0) {
            cursor -= 1;
            const item = if (is_typed_array) blk: {
                const current_length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));
                if (cursor >= current_length) continue;
                break :blk try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(cursor));
            } else blk: {
                const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
                defer key.deinit(ctx.runtime);
                if (!try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null)) continue;
                break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
            };
            defer item.free(ctx.runtime);
            if (try valuesStrictEqual(ctx.runtime, item, search_value)) return lengthIndexValue(cursor);
        }
    } else {
        var cursor = try arrayFirstIndexStart(ctx, output, global, args, length);
        while (cursor < length) : (cursor += 1) {
            const item = if (is_typed_array) blk: {
                if (mode != .includes) {
                    const current_length = @as(usize, @intCast(try builtins.buffer.typedArrayLength(ctx.runtime, object)));
                    if (cursor >= current_length) continue;
                }
                break :blk try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(cursor));
            } else blk: {
                const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
                defer key.deinit(ctx.runtime);
                if (mode != .includes and !try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null)) continue;
                break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
            };
            defer item.free(ctx.runtime);
            if (mode == .includes) {
                if (builtins.collection.sameValueZero(item, search_value)) return core.JSValue.boolean(true);
                continue;
            }
            if (try valuesStrictEqual(ctx.runtime, item, search_value)) return lengthIndexValue(cursor);
        }
    }
    return if (mode == .includes) core.JSValue.boolean(false) else core.JSValue.int32(-1);
}

pub fn qjsArrayConcatCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const function_object = callableObjectFromValue(func) orelse return null;
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.concat))) {
        const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
        defer ctx.runtime.memory.allocator.free(name);
        if (!std.mem.eql(u8, name, "concat")) return null;
        if (function_object.arrayBuiltinMarker() != .concat) return null;
    }

    if (receiver.isNull() or receiver.isUndefined()) return error.TypeError;
    const receiver_object_value = if (receiver.isObject()) receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer receiver_object_value.free(ctx.runtime);

    const out_value = try arraySpeciesCreate(ctx, output, global, receiver_object_value, 0, caller_function, caller_frame);
    errdefer out_value.free(ctx.runtime);
    const out = try property_ops.expectObject(out_value);
    var next_index: usize = 0;
    try concatAppendValue(ctx, output, global, out, &next_index, receiver_object_value, caller_function, caller_frame);
    for (args) |arg| try concatAppendValue(ctx, output, global, out, &next_index, arg, caller_function, caller_frame);
    if (next_index > core.array.max_array_length) return error.RangeError;
    const set_length = try setValueProperty(ctx, output, global, out_value, core.atom.ids.length, lengthIndexValue(next_index), caller_function, caller_frame);
    set_length.free(ctx.runtime);
    return out_value;
}

pub fn concatAppendValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    out: *core.Object,
    next_index: *usize,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const max_safe_length: usize = 9007199254740991;
    if (objectFromValue(value)) |object| {
        if (try isConcatSpreadable(ctx, output, global, value, object, caller_function, caller_frame)) {
            const length_value = try concatSpreadLengthValue(ctx, output, global, value, object, caller_function, caller_frame);
            defer length_value.free(ctx.runtime);
            const length = try toLengthIndex(ctx, output, global, length_value);
            if (next_index.* > max_safe_length or length > max_safe_length - next_index.*) return error.TypeError;
            var index: usize = 0;
            while (index < length) : (index += 1) {
                if (next_index.* > core.array.max_array_length) return error.RangeError;
                const from_key = try propertyAtomFromLengthIndex(ctx.runtime, index);
                defer from_key.deinit(ctx.runtime);
                if (try hasValueProperty(ctx, output, global, value, object, from_key.atom, null, null)) {
                    const item = try getValueProperty(ctx, output, global, value, from_key.atom, caller_function, caller_frame);
                    defer item.free(ctx.runtime);
                    const to_key = try propertyAtomFromLengthIndex(ctx.runtime, next_index.*);
                    defer to_key.deinit(ctx.runtime);
                    try createDataPropertyOrThrow(ctx, output, global, out.value(), out, to_key.atom, item, caller_function, caller_frame);
                }
                next_index.* += 1;
            }
            return;
        }
    }
    if (next_index.* >= max_safe_length) return error.TypeError;
    if (next_index.* > core.array.max_array_length) return error.RangeError;
    const key = try propertyAtomFromLengthIndex(ctx.runtime, next_index.*);
    defer key.deinit(ctx.runtime);
    try createDataPropertyOrThrow(ctx, output, global, out.value(), out, key.atom, value, caller_function, caller_frame);
    next_index.* += 1;
}

pub fn concatSpreadLengthValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const dynamic = try getValueProperty(ctx, output, global, value, core.atom.ids.length, caller_function, caller_frame);
    errdefer dynamic.free(ctx.runtime);
    if (!builtins.buffer.isTypedArrayObject(object) or object.typedArrayFixedLength() == null) return dynamic;
    if (try builtins.buffer.typedArrayOutOfBounds(object)) return dynamic;
    const own = object.getOwnProperty(core.atom.ids.length) orelse return dynamic;
    defer own.destroy(ctx.runtime);
    if (own.kind != .data or !own.value.isNumber() or !dynamic.isNumber()) return dynamic;
    const own_number = value_ops.numberValue(own.value) orelse return dynamic;
    const dynamic_number = value_ops.numberValue(dynamic) orelse return dynamic;
    if (own_number > dynamic_number) {
        dynamic.free(ctx.runtime);
        return own.value.dup();
    }
    return dynamic;
}

pub fn isConcatSpreadable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const spreadable_atom = core.atom.predefinedId("Symbol.isConcatSpreadable", .symbol) orelse return arraySpeciesOriginalIsArray(object);
    const spreadable = try getValueProperty(ctx, output, global, value, spreadable_atom, caller_function, caller_frame);
    defer spreadable.free(ctx.runtime);
    if (!spreadable.isUndefined()) return valueTruthy(spreadable);
    return arraySpeciesOriginalIsArray(object);
}

pub fn uint8ArrayStringBytes(rt: *core.JSRuntime, value: core.JSValue) !std.ArrayList(u8) {
    if (!value.isString()) return error.TypeError;
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &bytes, value);
    return bytes;
}

pub fn privateAtomNamesMatch(rt: *core.JSRuntime, left: core.Atom, right: core.Atom) bool {
    const left_name = rt.atoms.name(left) orelse return false;
    const right_name = rt.atoms.name(right) orelse return false;
    return std.mem.eql(u8, left_name, right_name);
}

pub const KeywordMatch = struct {
    index: usize,
    keyword: []const u8,
};

pub fn replaceFrameVarRefBinding(rt: *core.JSRuntime, frame: *frame_mod.Frame, atom_id: core.Atom, value: core.JSValue) void {
    const count = @min(frame.function.var_ref_names.len, frame.var_refs.len);
    for (frame.function.var_ref_names[0..count], 0..) |name, idx| {
        if (!atomIdOrNameEql(rt, name, atom_id)) continue;
        const next = value.dup();
        const old_value = frame.var_refs[idx];
        frame.var_refs[idx] = next;
        old_value.free(rt);
        return;
    }
}

pub fn appendSourceStringUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    const header = value.refHeader() orelse return error.TypeError;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            for (bytes) |byte| {
                if (byte < 0x80) {
                    try buffer.append(rt.memory.allocator, byte);
                } else {
                    try appendCodepointUtf8(rt, buffer, byte);
                }
            }
        },
        .utf16 => |units| {
            for (units) |unit| try appendCodepointUtf8(rt, buffer, unit);
        },
    }
}

pub fn appendCodepointUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), codepoint: u21) !void {
    if (codepoint <= 0x7f) {
        try buffer.append(rt.memory.allocator, @intCast(codepoint));
    } else if (codepoint <= 0x7ff) {
        try buffer.append(rt.memory.allocator, @intCast(0xc0 | (codepoint >> 6)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (codepoint & 0x3f)));
    } else if (codepoint <= 0xffff) {
        try buffer.append(rt.memory.allocator, @intCast(0xe0 | (codepoint >> 12)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((codepoint >> 6) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (codepoint & 0x3f)));
    } else {
        try buffer.append(rt.memory.allocator, @intCast(0xf0 | (codepoint >> 18)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((codepoint >> 12) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((codepoint >> 6) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (codepoint & 0x3f)));
    }
}

pub fn simpleEvalStringLiteral(rt: *core.JSRuntime, source: []const u8) ?core.JSValue {
    if (source.len < 2 or source[0] != '"' or source[source.len - 1] != '"') return null;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    var index: usize = 1;
    while (index + 1 < source.len) : (index += 1) {
        const ch = source[index];
        if (ch == '\\') {
            index += 1;
            if (index + 1 >= source.len) return null;
            const escaped = switch (source[index]) {
                '"', '\\', '/' => source[index],
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return null,
            };
            bytes.append(rt.memory.allocator, escaped) catch return null;
            continue;
        }
        bytes.append(rt.memory.allocator, ch) catch return null;
    }
    return value_ops.createStringValue(rt, bytes.items) catch null;
}

pub fn qjsIteratorConcatCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    return iter_vm.qjsIteratorConcatCall(ctx, output, global, args, arrayPrototypeFromGlobal, getIteratorMethod, isCallableValue);
}

pub fn qjsDefineToStringTag(rt: *core.JSRuntime, object: *core.Object, tag_name: []const u8) !void {
    return iter_vm.qjsDefineToStringTag(rt, object, tag_name);
}

pub fn qjsRegExpStringIteratorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const iterator = property_ops.expectObject(receiver) catch return null;
    if (iterator.class_id != core.class.ids.regexp_string_iterator) return null;
    if ((iterator.iteratorIndexSlot().*) != 0) return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    const regexp = (iterator.iteratorTargetSlot().*) orelse {
        const done_result = try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
        iterator.iteratorIndexSlot().* = 1;
        return done_result;
    };
    const string_value = iterator.iteratorData() orelse {
        const done_result = try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
        iterator.iteratorIndexSlot().* = 1;
        return done_result;
    };
    const result = try qjsRegExpExecGeneric(ctx, output, global, regexp, string_value, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (result.isNull()) {
        const done_result = try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
        iterator.iteratorIndexSlot().* = 1;
        iterator.clearOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot());
        iterator.clearOptionalValueSlot(ctx.runtime, iterator.iteratorDataSlot());
        return done_result;
    }
    const is_global = ((iterator.iteratorKindSlot().*) & 1) != 0;
    if (!is_global) iterator.iteratorIndexSlot().* = 1;
    const unicode = ((iterator.iteratorKindSlot().*) & 2) != 0;
    const zero_value = try getValueProperty(ctx, output, global, result, core.atom.atomFromUInt32(0), caller_function, caller_frame);
    defer zero_value.free(ctx.runtime);
    const match_string = try toStringForAnnexB(ctx, output, global, zero_value, caller_function, caller_frame);
    defer match_string.free(ctx.runtime);
    if (is_global and isEmptyStringValue(ctx.runtime, match_string)) {
        const last_index = try getValueProperty(ctx, output, global, regexp, core.atom.ids.lastIndex, caller_function, caller_frame);
        defer last_index.free(ctx.runtime);
        const next = try advanceStringIndexNumber(ctx, output, global, string_value, last_index, unicode);
        try setValuePropertyStrict(ctx, output, global, regexp, core.atom.ids.lastIndex, next, caller_function, caller_frame);
    }
    return try createIteratorResult(ctx.runtime, global, result, false);
}

pub fn getFastStringPrimitiveDataProperty(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) !?core.JSValue {
    if (!receiver.isString()) return null;
    if (!isStandardStringPrototypeMethodAtom(ctx.runtime, atom_id)) return null;

    const proto = constructorPrototypeFromGlobal(ctx.runtime, global, "String") orelse return null;
    return ownDataOrAutoInitPropertyValue(proto, atom_id);
}

pub fn isStandardStringPrototypeMethodAtom(rt: *core.JSRuntime, atom_id: core.Atom) bool {
    const name = rt.atoms.name(atom_id) orelse return false;
    return builtins.string.prototypeMethodId(name) != null;
}

pub fn defineStringWrapperIndexProperty(rt: *core.JSRuntime, object: *core.Object, index: u32, unit: u16) !void {
    const value = if (unit <= 0xff) blk: {
        const units: [1]u16 = .{unit};
        break :blk (try core.string.String.createUtf16(rt, &units)).value();
    } else blk: {
        const units: [1]u16 = .{unit};
        break :blk (try core.string.String.createUtf16(rt, &units)).value();
    };
    defer value.free(rt);
    try object.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(value, false, true, false));
}

pub fn getStringIndexValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !?core.JSValue {
    const index = core.array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return null;
    const header = value.refHeader() orelse return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    if (index >= string_value.len()) return core.JSValue.undefinedValue();
    const unit = string_value.codeUnitAt(index);
    if (unit <= 0x7f) {
        // ASCII fast path: reuse the runtime's cached single-byte
        // strings. Hot loops like `decimalToPercentHexString` in URI sweeps
        // hit this path thousands of times per inner
        // iteration, and avoiding the per-call header+bytes allocation
        // pair is a major speedup.
        const cached = (try rt.singleByteString(@intCast(unit))).?;
        const out = cached.value();
        return out.dup();
    }
    if (unit <= 0xff) {
        const units: [1]u16 = .{unit};
        const out = try core.string.String.createUtf16(rt, &units);
        return out.value();
    }
    const units: [1]u16 = .{unit};
    const out = try core.string.String.createUtf16(rt, &units);
    return out.value();
}

pub fn qjsArrayToStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.to_string))) {
        if (function_object.arrayBuiltinMarker() != .to_string) return null;
    }
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (this_value.isObject()) this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    const join_atom = try ctx.runtime.internAtom("join");
    defer ctx.runtime.atoms.free(join_atom);
    const join_value = try getValueProperty(ctx, output, global, object_value, join_atom, caller_function, caller_frame);
    defer join_value.free(ctx.runtime);
    if (isCallableValue(join_value)) {
        return try callValueOrBytecode(ctx, output, global, object_value, join_value, &.{}, caller_function, caller_frame);
    }
    return try qjsObjectToStringIntrinsic(ctx, output, global, object_value, caller_function, caller_frame);
}

pub fn qjsArrayToLocaleStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(builtins.array.PrototypeMethod.to_locale_string))) {
        if (function_object.arrayBuiltinMarker() != .to_locale_string) return null;
    }
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (this_value.isObject()) this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    const object = property_ops.expectObject(object_value) catch return null;
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    const is_typed_array = builtins.buffer.isTypedArrayObject(object);
    if (is_typed_method and !is_typed_array) return error.TypeError;
    const length = if (is_typed_array)
        try arrayMethodTypedArrayLength(ctx.runtime, object, is_typed_method)
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, object_value, core.atom.ids.length, caller_function, caller_frame);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    const to_locale_key = try ctx.runtime.internAtom("toLocaleString");
    defer ctx.runtime.atoms.free(to_locale_key);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);
    var index: usize = 0;
    while (index < length) : (index += 1) {
        if (index != 0) try bytes.append(ctx.runtime.memory.allocator, ',');
        const item = if (is_typed_array) blk: {
            if (!is_typed_method and index >= try arrayMethodTypedArrayLength(ctx.runtime, object, false)) break :blk core.JSValue.undefinedValue();
            break :blk try builtins.buffer.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
        } else blk: {
            const key = try propertyAtomFromLengthIndex(ctx.runtime, index);
            defer key.deinit(ctx.runtime);
            break :blk try getValueProperty(ctx, output, global, object_value, key.atom, caller_function, caller_frame);
        };
        defer item.free(ctx.runtime);
        if (!item.isUndefined() and !item.isNull()) {
            const method = try getValueProperty(ctx, output, global, item, to_locale_key, caller_function, caller_frame);
            defer method.free(ctx.runtime);
            const locale_value = try callValueOrBytecode(ctx, output, global, item, method, &.{}, caller_function, caller_frame);
            defer locale_value.free(ctx.runtime);
            const locale_string = try toStringForAnnexB(ctx, output, global, locale_value, caller_function, caller_frame);
            defer locale_string.free(ctx.runtime);
            try value_ops.appendRawString(ctx.runtime, &bytes, locale_string);
        }
    }
    return try value_ops.createStringValue(ctx.runtime, bytes.items);
}

pub fn qjsObjectToLocaleStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const to_string_key = try ctx.runtime.internAtom("toString");
    defer ctx.runtime.atoms.free(to_string_key);
    const method = try getValueProperty(ctx, output, global, this_value, to_string_key, caller_function, caller_frame);
    defer method.free(ctx.runtime);
    return try callValueOrBytecode(ctx, output, global, this_value, method, &.{}, caller_function, caller_frame);
}

pub fn qjsObjectToStringCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isUndefined()) return try qjsObjectTagString(ctx.runtime, "Undefined");
    if (this_value.isNull()) return try qjsObjectTagString(ctx.runtime, "Null");
    const object_value = if (this_value.isObject()) this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    return try qjsObjectToStringIntrinsic(ctx, output, global, object_value, caller_function, caller_frame);
}

pub fn qjsObjectToStringIntrinsic(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const object = try property_ops.expectObject(object_value);
    const builtin_tag = try defaultObjectToStringTag(object);
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return try qjsObjectTagString(ctx.runtime, "Object");
    const tag_value = try getValueProperty(ctx, output, global, object_value, tag_atom, caller_function, caller_frame);
    defer tag_value.free(ctx.runtime);
    if (tag_value.isString()) {
        var tag = std.ArrayList(u8).empty;
        defer tag.deinit(ctx.runtime.memory.allocator);
        try value_ops.appendRawString(ctx.runtime, &tag, tag_value);
        return try qjsObjectTagString(ctx.runtime, tag.items);
    }
    return try qjsObjectTagString(ctx.runtime, builtin_tag);
}

pub fn qjsObjectTagString(rt: *core.JSRuntime, tag: []const u8) !core.JSValue {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try bytes.appendSlice(rt.memory.allocator, "[object ");
    try bytes.appendSlice(rt.memory.allocator, tag);
    try bytes.appendSlice(rt.memory.allocator, "]");
    return value_ops.createStringValue(rt, bytes.items);
}

pub fn defaultObjectToStringTag(object: *core.Object) ![]const u8 {
    if (object.is_proxy) {
        if (object.proxyHandler() == null) return error.TypeError;
        if (object.proxyTarget()) |target_value| {
            if (objectFromValue(target_value)) |target| {
                if (try objectIsArrayForToString(target)) return "Array";
                if (proxyTargetIsCallableObject(target)) return "Function";
            }
        }
        return "Object";
    }
    if (object.is_array) return "Array";
    return switch (object.class_id) {
        core.class.ids.arguments, core.class.ids.mapped_arguments => "Arguments",
        core.class.ids.error_ => "Error",
        core.class.ids.generator_function => "GeneratorFunction",
        core.class.ids.async_function => "AsyncFunction",
        core.class.ids.bytecode_function => bytecodeFunctionObjectTag(object),
        core.class.ids.c_function,
        core.class.ids.bound_function,
        core.class.ids.c_function_data,
        core.class.ids.c_closure,
        => "Function",
        core.class.ids.boolean => "Boolean",
        core.class.ids.number => "Number",
        core.class.ids.string => "String",
        core.class.ids.date => "Date",
        core.class.ids.regexp => "RegExp",
        core.class.ids.array_buffer => "ArrayBuffer",
        else => "Object",
    };
}

pub fn objectIsArrayForToString(object: *core.Object) !bool {
    if (object.is_array) return true;
    if (!object.is_proxy) return false;
    if (object.proxyHandler() == null) return error.TypeError;
    const target_value = object.proxyTarget() orelse return false;
    const target = objectFromValue(target_value) orelse return false;
    return objectIsArrayForToString(target);
}

pub fn stringObjectHasIndexProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    if (object.class_id != core.class.ids.string) return false;
    const string_data = object.objectData() orelse return false;
    const index = core.array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return false;
    const header = string_data.refHeader() orelse return false;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return index < string_value.len();
}
