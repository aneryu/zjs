const std = @import("std");
const bytecode = @import("../../bytecode/root.zig");
const builtins = @import("../../builtins/root.zig");
const core = @import("../../core/root.zig");
const quickjs_regexp = @import("../../libs/quickjs_regexp.zig");
const unicode_lib = @import("../../libs/unicode.zig");
const unicode_tables = @import("../../libs/unicode_tables.zig");
const call_mod = @import("../call.zig");
const frame_mod = @import("../frame.zig");
const iter_vm = @import("iter.zig");
const property_ops = @import("../property_ops.zig");
const value_ops = @import("../value_ops.zig");

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
const test262PageAllocator = shared_vm.test262PageAllocator;
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

pub fn simpleAsciiLiteralPlusLiteralMatch(source: []const u8, flags: []const u8, string_value: core.JSValue) ?bool {
    const input = latin1StringSlice(string_value) orelse return null;
    return simpleAsciiLiteralPlusLiteralMatchBytes(source, flags, input);
}

pub fn simpleAsciiLiteralPlusLiteralMatchBytes(source: []const u8, flags: []const u8, input: []const u8) ?bool {
    if (flags.len != 0 or source.len < 2 or source[1] != '+') return null;
    const repeat = source[0];
    if (!isPlainAsciiRegExpLiteral(repeat)) return null;

    if (source.len == 2) {
        return std.mem.indexOfScalar(u8, input, repeat) != null;
    }

    if (source.len != 3) return null;
    const tail = source[2];
    if (!isPlainAsciiRegExpLiteral(tail)) return null;

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != repeat) continue;
        var j = i + 1;
        while (j < input.len and input[j] == repeat) : (j += 1) {}
        if (j < input.len and input[j] == tail) return true;
    }
    return false;
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
    const match = unicode_tables.findRgiEmojiMatch(units, start_index, sticky) orelse return null;
    return .{ .index = match.index, .len = match.len };
}

pub fn anchoredRgiEmojiMatches(string_value: core.JSValue) bool {
    const units = stringValueUnits(string_value) orelse return false;
    return unicode_tables.rgiEmojiSequencesCover(units);
}

pub fn stringValueUnits(string_value: core.JSValue) ?unicode_tables.StringUnits {
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
    if (method_id == 27) {
        return qjsStringSplit(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == 40) {
        return qjsStringSearch(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == 41) {
        return qjsStringMatch(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == 42) {
        return qjsStringReplaceAll(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == 43) {
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
    if (method_id == 37) {
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
    const result = try builtins.string.methodCall(ctx.runtime, string_value, 27, args);
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
    if (std.mem.eql(u8, name, "Assigned")) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeAssignedCodePoint);
    }
    if (std.mem.eql(u8, name, "Lowercase") or std.mem.eql(u8, name, "Lower")) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeLowercaseCodePoint);
    }
    if (std.mem.eql(u8, name, "Uppercase") or std.mem.eql(u8, name, "Upper")) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeUppercaseCodePoint);
    }
    if (isUnassignedGeneralCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeUnassignedCodePoint);
    }
    if (isOtherGeneralCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOtherCategoryCodePoint);
    }
    if (isControlGeneralCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeControlCategoryCodePoint);
    }
    if (isDecimalNumberGeneralCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeDecimalNumberCategoryCodePoint);
    }
    if (isMarkGeneralCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMarkCategoryCodePoint);
    }
    if (isLetterGeneralCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeLetterCategoryCodePoint);
    }
    if (isOtherLetterGeneralCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOtherLetterCategoryCodePoint);
    }
    if (isUppercaseLetterGeneralCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeUppercaseLetterCategoryCodePoint);
    }
    if (isPunctuationGeneralCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePunctuationCategoryCodePoint);
    }
    if (isSymbolGeneralCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSymbolCategoryCodePoint);
    }
    if (isArabicScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeArabicScriptExtensionsCodePoint);
    }
    if (isArmenianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeArmenianScriptExtensionsCodePoint);
    }
    if (isAvestanScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeAvestanScriptExtensionsCodePoint);
    }
    if (isAdlamScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeAdlamScriptExtensionsCodePoint);
    }
    if (isBengaliScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeBengaliScriptExtensionsCodePoint);
    }
    if (isBopomofoScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeBopomofoScriptExtensionsCodePoint);
    }
    if (isBugineseScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeBugineseScriptExtensionsCodePoint);
    }
    if (isCarianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeCarianScriptExtensionsCodePoint);
    }
    if (isCaucasianAlbanianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeCaucasianAlbanianScriptExtensionsCodePoint);
    }
    if (isChakmaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeChakmaScriptExtensionsCodePoint);
    }
    if (isCherokeeScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeCherokeeScriptExtensionsCodePoint);
    }
    if (isCopticScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeCopticScriptCodePoint);
    }
    if (isCommonScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeCommonScriptExtensionsCodePoint);
    }
    if (isCopticScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeCopticScriptExtensionsCodePoint);
    }
    if (isNumberCategoryName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNumberCategoryCodePoint);
    }
    if (isGraphemeBaseName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeGraphemeBaseCodePoint);
    }
    if (isIdContinueName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeIdContinueCodePoint);
    }
    if (isXidContinueName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeXidContinueCodePoint);
    }
    if (isTolongSikiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTolongSikiScriptExtensionsCodePoint);
    }
    if (isWanchoScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeWanchoScriptExtensionsCodePoint);
    }
    if (isWarangCitiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeWarangCitiScriptExtensionsCodePoint);
    }
    if (isZanabazarSquareScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeZanabazarSquareScriptExtensionsCodePoint);
    }
    if (isCypriotScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeCypriotScriptExtensionsCodePoint);
    }
    if (isCyrillicScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeCyrillicScriptExtensionsCodePoint);
    }
    if (isDevanagariScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeDevanagariScriptExtensionsCodePoint);
    }
    if (isDograScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeDograScriptExtensionsCodePoint);
    }
    if (isDuployanScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeDuployanScriptExtensionsCodePoint);
    }
    if (isElbasanScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeElbasanScriptExtensionsCodePoint);
    }
    if (isEthiopicScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeEthiopicScriptExtensionsCodePoint);
    }
    if (isGarayScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeGarayScriptExtensionsCodePoint);
    }
    if (isGeorgianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeGeorgianScriptExtensionsCodePoint);
    }
    if (isGlagoliticScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeGlagoliticScriptExtensionsCodePoint);
    }
    if (isUgariticScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeUgariticScriptExtensionsCodePoint);
    }
    if (isVaiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeVaiScriptExtensionsCodePoint);
    }
    if (isVithkuqiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeVithkuqiScriptExtensionsCodePoint);
    }
    if (isSoraSompengScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSoraSompengScriptExtensionsCodePoint);
    }
    if (isTangsaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTangsaScriptExtensionsCodePoint);
    }
    if (isGothicScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeGothicScriptExtensionsCodePoint);
    }
    if (isGranthaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeGranthaScriptExtensionsCodePoint);
    }
    if (isGreekScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeGreekScriptExtensionsCodePoint);
    }
    if (isGujaratiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeGujaratiScriptExtensionsCodePoint);
    }
    if (isGunjalaGondiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeGunjalaGondiScriptExtensionsCodePoint);
    }
    if (isGurmukhiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeGurmukhiScriptExtensionsCodePoint);
    }
    if (isHanunooScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeHanunooScriptExtensionsCodePoint);
    }
    if (isImperialAramaicScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeImperialAramaicScriptExtensionsCodePoint);
    }
    if (isKawiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeKawiScriptExtensionsCodePoint);
    }
    if (isKayahLiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeKayahLiScriptExtensionsCodePoint);
    }
    if (isLaoScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeLaoScriptExtensionsCodePoint);
    }
    if (isLycianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeLycianScriptExtensionsCodePoint);
    }
    if (isMedefaidrinScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMedefaidrinScriptExtensionsCodePoint);
    }
    if (isMeeteiMayekScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMeeteiMayekScriptExtensionsCodePoint);
    }
    if (isMendeKikakuiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMendeKikakuiScriptExtensionsCodePoint);
    }
    if (isMeroiticCursiveScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMeroiticCursiveScriptExtensionsCodePoint);
    }
    if (isMeroiticHieroglyphsScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMeroiticHieroglyphsScriptExtensionsCodePoint);
    }
    if (isMroScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMroScriptExtensionsCodePoint);
    }
    if (isNabataeanScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNabataeanScriptExtensionsCodePoint);
    }
    if (isNushuScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNushuScriptExtensionsCodePoint);
    }
    if (isLinearAScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeLinearAScriptExtensionsCodePoint);
    }
    if (isLinearBScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeLinearBScriptExtensionsCodePoint);
    }
    if (isLisuScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeLisuScriptExtensionsCodePoint);
    }
    if (isLydianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeLydianScriptExtensionsCodePoint);
    }
    if (isMahajaniScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMahajaniScriptExtensionsCodePoint);
    }
    if (isManichaeanScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeManichaeanScriptExtensionsCodePoint);
    }
    if (isMasaramGondiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMasaramGondiScriptExtensionsCodePoint);
    }
    if (isMultaniScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMultaniScriptExtensionsCodePoint);
    }
    if (isHanScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeHanScriptCodePoint);
    }
    if (isHanScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeHanScriptExtensionsCodePoint);
    }
    if (isHangulScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeHangulScriptExtensionsCodePoint);
    }
    if (isHanifiRohingyaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeHanifiRohingyaScriptExtensionsCodePoint);
    }
    if (isHebrewScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeHebrewScriptExtensionsCodePoint);
    }
    if (isHiraganaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeHiraganaScriptExtensionsCodePoint);
    }
    if (isInheritedScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeInheritedScriptCodePoint);
    }
    if (isInheritedScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeInheritedScriptExtensionsCodePoint);
    }
    if (isJavaneseScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeJavaneseScriptExtensionsCodePoint);
    }
    if (isKaithiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeKaithiScriptExtensionsCodePoint);
    }
    if (isKannadaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeKannadaScriptExtensionsCodePoint);
    }
    if (isKatakanaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeKatakanaScriptExtensionsCodePoint);
    }
    if (isKhojkiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeKhojkiScriptExtensionsCodePoint);
    }
    if (isKhudawadiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeKhudawadiScriptExtensionsCodePoint);
    }
    if (isLatinScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeLatinScriptExtensionsCodePoint);
    }
    if (isLimbuScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeLimbuScriptExtensionsCodePoint);
    }
    if (isMalayalamScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMalayalamScriptExtensionsCodePoint);
    }
    if (isMandaicScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMandaicScriptExtensionsCodePoint);
    }
    if (isModiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeModiScriptExtensionsCodePoint);
    }
    if (isMongolianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMongolianScriptExtensionsCodePoint);
    }
    if (isMyanmarScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMyanmarScriptExtensionsCodePoint);
    }
    if (isNagMundariScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNagMundariScriptExtensionsCodePoint);
    }
    if (isNandinagariScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNandinagariScriptExtensionsCodePoint);
    }
    if (isMiaoScriptName(name) or isMiaoScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeMiaoScriptCodePoint);
    }
    if (isNandinagariScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNandinagariScriptCodePoint);
    }
    if (isKiratRaiScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeKiratRaiScriptCodePoint);
    }
    if (isNewaScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNewaScriptCodePoint);
    }
    if (isNewTaiLueScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNewTaiLueScriptCodePoint);
    }
    if (isNewaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNewaScriptExtensionsCodePoint);
    }
    if (isNewTaiLueScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNewTaiLueScriptExtensionsCodePoint);
    }
    if (isNkoScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNkoScriptExtensionsCodePoint);
    }
    if (isOldHungarianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldHungarianScriptExtensionsCodePoint);
    }
    if (isOldPermicScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldPermicScriptExtensionsCodePoint);
    }
    if (isOldPersianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldPersianScriptExtensionsCodePoint);
    }
    if (isOldSogdianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldSogdianScriptExtensionsCodePoint);
    }
    if (isOldTurkicScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldTurkicScriptExtensionsCodePoint);
    }
    if (isOldUyghurScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldUyghurScriptExtensionsCodePoint);
    }
    if (isNkoScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNkoScriptCodePoint);
    }
    if (isNushuScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNushuScriptCodePoint);
    }
    if (isNyiakengPuachueHmongScriptName(name) or isNyiakengPuachueHmongScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeNyiakengPuachueHmongScriptCodePoint);
    }
    if (isOghamScriptName(name) or isOghamScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOghamScriptCodePoint);
    }
    if (isOlChikiScriptName(name) or isOlChikiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOlChikiScriptCodePoint);
    }
    if (isOlOnalScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOlOnalScriptCodePoint);
    }
    if (isOlOnalScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOlOnalScriptExtensionsCodePoint);
    }
    if (isOldHungarianScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldHungarianScriptCodePoint);
    }
    if (isOldPermicScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldPermicScriptCodePoint);
    }
    if (isOldPersianScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldPersianScriptCodePoint);
    }
    if (isOldItalicScriptName(name) or isOldItalicScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldItalicScriptCodePoint);
    }
    if (isOldNorthArabianScriptName(name) or isOldNorthArabianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldNorthArabianScriptCodePoint);
    }
    if (isOldSogdianScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldSogdianScriptCodePoint);
    }
    if (isOldSouthArabianScriptName(name) or isOldSouthArabianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldSouthArabianScriptCodePoint);
    }
    if (isOldTurkicScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldTurkicScriptCodePoint);
    }
    if (isOldUyghurScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOldUyghurScriptCodePoint);
    }
    if (isOriyaScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOriyaScriptCodePoint);
    }
    if (isOsageScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOsageScriptCodePoint);
    }
    if (isOsmanyaScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOsmanyaScriptCodePoint);
    }
    if (isPahawhHmongScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePahawhHmongScriptCodePoint);
    }
    if (isPalmyreneScriptName(name) or isPalmyreneScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePalmyreneScriptCodePoint);
    }
    if (isPauCinHauScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePauCinHauScriptCodePoint);
    }
    if (isPhagsPaScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePhagsPaScriptCodePoint);
    }
    if (isPhoenicianScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePhoenicianScriptCodePoint);
    }
    if (isPsalterPahlaviScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePsalterPahlaviScriptCodePoint);
    }
    if (isRejangScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeRejangScriptCodePoint);
    }
    if (isRunicScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeRunicScriptCodePoint);
    }
    if (isSamaritanScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSamaritanScriptCodePoint);
    }
    if (isSaurashtraScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSaurashtraScriptCodePoint);
    }
    if (isSharadaScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSharadaScriptCodePoint);
    }
    if (isShavianScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeShavianScriptCodePoint);
    }
    if (isSiddhamScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSiddhamScriptCodePoint);
    }
    if (isSideticScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSideticScriptCodePoint);
    }
    if (isSignWritingScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSignWritingScriptCodePoint);
    }
    if (isSinhalaScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSinhalaScriptCodePoint);
    }
    if (isSogdianScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSogdianScriptCodePoint);
    }
    if (isSoraSompengScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSoraSompengScriptCodePoint);
    }
    if (isSoyomboScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSoyomboScriptCodePoint);
    }
    if (isSundaneseScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSundaneseScriptCodePoint);
    }
    if (isSunuwarScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSunuwarScriptCodePoint);
    }
    if (isSylotiNagriScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSylotiNagriScriptCodePoint);
    }
    if (isSyriacScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSyriacScriptCodePoint);
    }
    if (isTagalogScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTagalogScriptCodePoint);
    }
    if (isTagbanwaScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTagbanwaScriptCodePoint);
    }
    if (isTaiLeScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTaiLeScriptCodePoint);
    }
    if (isTaiThamScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTaiThamScriptCodePoint);
    }
    if (isTaiVietScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTaiVietScriptCodePoint);
    }
    if (isTaiYoScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTaiYoScriptCodePoint);
    }
    if (isTakriScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTakriScriptCodePoint);
    }
    if (isTamilScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTamilScriptCodePoint);
    }
    if (isTangsaScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTangsaScriptCodePoint);
    }
    if (isTangutScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTangutScriptCodePoint);
    }
    if (isTeluguScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTeluguScriptCodePoint);
    }
    if (isThaanaScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeThaanaScriptCodePoint);
    }
    if (isThaiScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeThaiScriptCodePoint);
    }
    if (isTibetanScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTibetanScriptCodePoint);
    }
    if (isTifinaghScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTifinaghScriptCodePoint);
    }
    if (isTirhutaScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTirhutaScriptCodePoint);
    }
    if (isTodhriScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTodhriScriptCodePoint);
    }
    if (isTolongSikiScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTolongSikiScriptCodePoint);
    }
    if (isTotoScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTotoScriptCodePoint);
    }
    if (isTuluTigalariScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTuluTigalariScriptCodePoint);
    }
    if (isUgariticScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeUgariticScriptCodePoint);
    }
    if (isVaiScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeVaiScriptCodePoint);
    }
    if (isUnknownScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeUnknownScriptCodePoint);
    }
    if (isVithkuqiScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeVithkuqiScriptCodePoint);
    }
    if (isWanchoScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeWanchoScriptCodePoint);
    }
    if (isWarangCitiScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeWarangCitiScriptCodePoint);
    }
    if (isYezidiScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeYezidiScriptCodePoint);
    }
    if (isYiScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeYiScriptCodePoint);
    }
    if (isZanabazarSquareScriptName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeZanabazarSquareScriptCodePoint);
    }
    if (isOriyaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOriyaScriptExtensionsCodePoint);
    }
    if (isOsageScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOsageScriptExtensionsCodePoint);
    }
    if (isOsmanyaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeOsmanyaScriptExtensionsCodePoint);
    }
    if (isPahawhHmongScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePahawhHmongScriptExtensionsCodePoint);
    }
    if (isPauCinHauScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePauCinHauScriptExtensionsCodePoint);
    }
    if (isPhagsPaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePhagsPaScriptExtensionsCodePoint);
    }
    if (isPhoenicianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePhoenicianScriptExtensionsCodePoint);
    }
    if (isPsalterPahlaviScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodePsalterPahlaviScriptExtensionsCodePoint);
    }
    if (isRejangScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeRejangScriptExtensionsCodePoint);
    }
    if (isRunicScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeRunicScriptExtensionsCodePoint);
    }
    if (isSamaritanScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSamaritanScriptExtensionsCodePoint);
    }
    if (isSaurashtraScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSaurashtraScriptExtensionsCodePoint);
    }
    if (isSharadaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSharadaScriptExtensionsCodePoint);
    }
    if (isShavianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeShavianScriptExtensionsCodePoint);
    }
    if (isSiddhamScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSiddhamScriptExtensionsCodePoint);
    }
    if (isSideticScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSideticScriptExtensionsCodePoint);
    }
    if (isSinhalaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSinhalaScriptExtensionsCodePoint);
    }
    if (isSogdianScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSogdianScriptExtensionsCodePoint);
    }
    if (isSoyomboScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSoyomboScriptExtensionsCodePoint);
    }
    if (isSundaneseScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSundaneseScriptExtensionsCodePoint);
    }
    if (isSunuwarScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSunuwarScriptExtensionsCodePoint);
    }
    if (isSylotiNagriScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSylotiNagriScriptExtensionsCodePoint);
    }
    if (isSyriacScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSyriacScriptExtensionsCodePoint);
    }
    if (isTagalogScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTagalogScriptExtensionsCodePoint);
    }
    if (isTagbanwaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTagbanwaScriptExtensionsCodePoint);
    }
    if (isTaiLeScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTaiLeScriptExtensionsCodePoint);
    }
    if (isTakriScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTakriScriptExtensionsCodePoint);
    }
    if (isTangutScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTangutScriptExtensionsCodePoint);
    }
    if (isTeluguScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTeluguScriptExtensionsCodePoint);
    }
    if (isThaanaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeThaanaScriptExtensionsCodePoint);
    }
    if (isThaiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeThaiScriptExtensionsCodePoint);
    }
    if (isTibetanScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTibetanScriptExtensionsCodePoint);
    }
    if (isTifinaghScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTifinaghScriptExtensionsCodePoint);
    }
    if (isTirhutaScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTirhutaScriptExtensionsCodePoint);
    }
    if (isTodhriScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTodhriScriptExtensionsCodePoint);
    }
    if (isTotoScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTotoScriptExtensionsCodePoint);
    }
    if (isTuluTigalariScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTuluTigalariScriptExtensionsCodePoint);
    }
    if (isTamilScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTamilScriptExtensionsCodePoint);
    }
    if (isYezidiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeYezidiScriptExtensionsCodePoint);
    }
    if (isYiScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeYiScriptExtensionsCodePoint);
    }
    if (isTaiThamScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTaiThamScriptExtensionsCodePoint);
    }
    if (isTaiVietScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTaiVietScriptExtensionsCodePoint);
    }
    if (isTaiYoScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeTaiYoScriptExtensionsCodePoint);
    }
    if (isSignWritingScriptExtensionsName(name)) {
        return anchoredCodePointPredicateMatches(string_object, positive, isUnicodeSignWritingScriptExtensionsCodePoint);
    }
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            if (bytes.len == 0) return false;
            for (bytes) |byte| {
                const matched = binaryPropertyCodePointMatches(name, byte);
                if (matched != positive) return false;
            }
            return true;
        },
        .utf16 => |units| {
            if (units.len == 0) return false;
            var index: usize = 0;
            while (index < units.len) {
                const code_point = readUtf16CodePoint(units, &index);
                const matched = binaryPropertyCodePointMatches(name, code_point);
                if (matched != positive) return false;
            }
            return true;
        },
    }
}

pub fn anchoredCodePointPredicateMatches(
    string_object: *core.string.String,
    positive: bool,
    comptime predicate: fn (u21) bool,
) bool {
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            if (bytes.len == 0) return false;
            for (bytes) |byte| {
                if (predicate(byte) != positive) return false;
            }
            return true;
        },
        .utf16 => |units| {
            if (units.len == 0) return false;
            var index: usize = 0;
            while (index < units.len) {
                if (predicate(readUtf16CodePoint(units, &index)) != positive) return false;
            }
            return true;
        },
    }
}

pub fn binaryPropertyCodePointMatches(name: []const u8, code_point: u21) bool {
    if (exactScriptExtensionsAliasTarget(name)) |script_name| {
        return binaryPropertyCodePointMatches(script_name, code_point);
    }
    if (isArabicScriptExtensionsName(name)) {
        return isUnicodeArabicScriptExtensionsCodePoint(code_point);
    }
    if (isArmenianScriptExtensionsName(name)) {
        return isUnicodeArmenianScriptExtensionsCodePoint(code_point);
    }
    if (isAvestanScriptExtensionsName(name)) {
        return isUnicodeAvestanScriptExtensionsCodePoint(code_point);
    }
    if (isAdlamScriptExtensionsName(name)) {
        return isUnicodeAdlamScriptExtensionsCodePoint(code_point);
    }
    if (isBengaliScriptExtensionsName(name)) {
        return isUnicodeBengaliScriptExtensionsCodePoint(code_point);
    }
    if (isBopomofoScriptExtensionsName(name)) {
        return isUnicodeBopomofoScriptExtensionsCodePoint(code_point);
    }
    if (isBugineseScriptExtensionsName(name)) {
        return isUnicodeBugineseScriptExtensionsCodePoint(code_point);
    }
    if (isCarianScriptExtensionsName(name)) {
        return isUnicodeCarianScriptExtensionsCodePoint(code_point);
    }
    if (isCaucasianAlbanianScriptExtensionsName(name)) {
        return isUnicodeCaucasianAlbanianScriptExtensionsCodePoint(code_point);
    }
    if (isChakmaScriptExtensionsName(name)) {
        return isUnicodeChakmaScriptExtensionsCodePoint(code_point);
    }
    if (isCherokeeScriptExtensionsName(name)) {
        return isUnicodeCherokeeScriptExtensionsCodePoint(code_point);
    }
    if (isCommonScriptExtensionsName(name)) {
        return isUnicodeCommonScriptExtensionsCodePoint(code_point);
    }
    if (isCopticScriptExtensionsName(name)) {
        return isUnicodeCopticScriptExtensionsCodePoint(code_point);
    }
    if (isCypriotScriptExtensionsName(name)) {
        return isUnicodeCypriotScriptExtensionsCodePoint(code_point);
    }
    if (isCyrillicScriptExtensionsName(name)) {
        return isUnicodeCyrillicScriptExtensionsCodePoint(code_point);
    }
    if (isDevanagariScriptExtensionsName(name)) {
        return isUnicodeDevanagariScriptExtensionsCodePoint(code_point);
    }
    if (isDograScriptExtensionsName(name)) {
        return isUnicodeDograScriptExtensionsCodePoint(code_point);
    }
    if (isDuployanScriptExtensionsName(name)) {
        return isUnicodeDuployanScriptExtensionsCodePoint(code_point);
    }
    if (isElbasanScriptExtensionsName(name)) {
        return isUnicodeElbasanScriptExtensionsCodePoint(code_point);
    }
    if (isEthiopicScriptExtensionsName(name)) {
        return isUnicodeEthiopicScriptExtensionsCodePoint(code_point);
    }
    if (isGarayScriptExtensionsName(name)) {
        return isUnicodeGarayScriptExtensionsCodePoint(code_point);
    }
    if (isGeorgianScriptExtensionsName(name)) {
        return isUnicodeGeorgianScriptExtensionsCodePoint(code_point);
    }
    if (isGlagoliticScriptExtensionsName(name)) {
        return isUnicodeGlagoliticScriptExtensionsCodePoint(code_point);
    }
    if (isGothicScriptExtensionsName(name)) {
        return isUnicodeGothicScriptExtensionsCodePoint(code_point);
    }
    if (isGreekScriptExtensionsName(name)) {
        return isUnicodeGreekScriptExtensionsCodePoint(code_point);
    }
    if (isGujaratiScriptExtensionsName(name)) {
        return isUnicodeGujaratiScriptExtensionsCodePoint(code_point);
    }
    if (isGunjalaGondiScriptExtensionsName(name)) {
        return isUnicodeGunjalaGondiScriptExtensionsCodePoint(code_point);
    }
    if (isGurmukhiScriptExtensionsName(name)) {
        return isUnicodeGurmukhiScriptExtensionsCodePoint(code_point);
    }
    if (isHanScriptName(name)) {
        return isUnicodeHanScriptCodePoint(code_point);
    }
    if (isHanScriptExtensionsName(name)) {
        return isUnicodeHanScriptExtensionsCodePoint(code_point);
    }
    if (isHangulScriptExtensionsName(name)) {
        return isUnicodeHangulScriptExtensionsCodePoint(code_point);
    }
    if (isHanifiRohingyaScriptExtensionsName(name)) {
        return isUnicodeHanifiRohingyaScriptExtensionsCodePoint(code_point);
    }
    if (isHebrewScriptExtensionsName(name)) {
        return isUnicodeHebrewScriptExtensionsCodePoint(code_point);
    }
    if (isHiraganaScriptExtensionsName(name)) {
        return isUnicodeHiraganaScriptExtensionsCodePoint(code_point);
    }
    if (isInheritedScriptExtensionsName(name)) {
        return isUnicodeInheritedScriptExtensionsCodePoint(code_point);
    }
    if (isJavaneseScriptExtensionsName(name)) {
        return isUnicodeJavaneseScriptExtensionsCodePoint(code_point);
    }
    if (isKaithiScriptExtensionsName(name)) {
        return isUnicodeKaithiScriptExtensionsCodePoint(code_point);
    }
    if (isKannadaScriptExtensionsName(name)) {
        return isUnicodeKannadaScriptExtensionsCodePoint(code_point);
    }
    if (isKatakanaScriptExtensionsName(name)) {
        return isUnicodeKatakanaScriptExtensionsCodePoint(code_point);
    }
    if (isKhojkiScriptExtensionsName(name)) {
        return isUnicodeKhojkiScriptExtensionsCodePoint(code_point);
    }
    if (isKhudawadiScriptExtensionsName(name)) {
        return isUnicodeKhudawadiScriptExtensionsCodePoint(code_point);
    }
    if (isLatinScriptExtensionsName(name)) {
        return isUnicodeLatinScriptExtensionsCodePoint(code_point);
    }
    if (isLimbuScriptExtensionsName(name)) {
        return isUnicodeLimbuScriptExtensionsCodePoint(code_point);
    }
    if (isMalayalamScriptExtensionsName(name)) {
        return isUnicodeMalayalamScriptExtensionsCodePoint(code_point);
    }
    if (isMandaicScriptExtensionsName(name)) {
        return isUnicodeMandaicScriptExtensionsCodePoint(code_point);
    }
    if (isModiScriptExtensionsName(name)) {
        return isUnicodeModiScriptExtensionsCodePoint(code_point);
    }
    if (isMongolianScriptExtensionsName(name)) {
        return isUnicodeMongolianScriptExtensionsCodePoint(code_point);
    }
    if (isMyanmarScriptExtensionsName(name)) {
        return isUnicodeMyanmarScriptExtensionsCodePoint(code_point);
    }
    if (isNagMundariScriptExtensionsName(name)) {
        return isUnicodeNagMundariScriptExtensionsCodePoint(code_point);
    }
    if (isNandinagariScriptExtensionsName(name)) {
        return isUnicodeNandinagariScriptExtensionsCodePoint(code_point);
    }
    if (isNewaScriptExtensionsName(name)) {
        return isUnicodeNewaScriptExtensionsCodePoint(code_point);
    }
    if (isNewTaiLueScriptExtensionsName(name)) {
        return isUnicodeNewTaiLueScriptExtensionsCodePoint(code_point);
    }
    if (isNkoScriptExtensionsName(name)) {
        return isUnicodeNkoScriptExtensionsCodePoint(code_point);
    }
    if (isOldHungarianScriptExtensionsName(name)) {
        return isUnicodeOldHungarianScriptExtensionsCodePoint(code_point);
    }
    if (isOldPermicScriptExtensionsName(name)) {
        return isUnicodeOldPermicScriptExtensionsCodePoint(code_point);
    }
    if (isOldPersianScriptExtensionsName(name)) {
        return isUnicodeOldPersianScriptExtensionsCodePoint(code_point);
    }
    if (isOldSogdianScriptExtensionsName(name)) {
        return isUnicodeOldSogdianScriptExtensionsCodePoint(code_point);
    }
    if (isOldTurkicScriptExtensionsName(name)) {
        return isUnicodeOldTurkicScriptExtensionsCodePoint(code_point);
    }
    if (isOldUyghurScriptExtensionsName(name)) {
        return isUnicodeOldUyghurScriptExtensionsCodePoint(code_point);
    }
    if (isOriyaScriptExtensionsName(name)) {
        return isUnicodeOriyaScriptExtensionsCodePoint(code_point);
    }
    if (isOsageScriptExtensionsName(name)) {
        return isUnicodeOsageScriptExtensionsCodePoint(code_point);
    }
    if (isOsmanyaScriptExtensionsName(name)) {
        return isUnicodeOsmanyaScriptExtensionsCodePoint(code_point);
    }
    if (isPahawhHmongScriptExtensionsName(name)) {
        return isUnicodePahawhHmongScriptExtensionsCodePoint(code_point);
    }
    if (isPauCinHauScriptExtensionsName(name)) {
        return isUnicodePauCinHauScriptExtensionsCodePoint(code_point);
    }
    if (isPhagsPaScriptExtensionsName(name)) {
        return isUnicodePhagsPaScriptExtensionsCodePoint(code_point);
    }
    if (isPhoenicianScriptExtensionsName(name)) {
        return isUnicodePhoenicianScriptExtensionsCodePoint(code_point);
    }
    if (isPsalterPahlaviScriptExtensionsName(name)) {
        return isUnicodePsalterPahlaviScriptExtensionsCodePoint(code_point);
    }
    if (isRejangScriptExtensionsName(name)) {
        return isUnicodeRejangScriptExtensionsCodePoint(code_point);
    }
    if (isRunicScriptExtensionsName(name)) {
        return isUnicodeRunicScriptExtensionsCodePoint(code_point);
    }
    if (isSamaritanScriptExtensionsName(name)) {
        return isUnicodeSamaritanScriptExtensionsCodePoint(code_point);
    }
    if (isSaurashtraScriptExtensionsName(name)) {
        return isUnicodeSaurashtraScriptExtensionsCodePoint(code_point);
    }
    if (isSharadaScriptExtensionsName(name)) {
        return isUnicodeSharadaScriptExtensionsCodePoint(code_point);
    }
    if (isShavianScriptExtensionsName(name)) {
        return isUnicodeShavianScriptExtensionsCodePoint(code_point);
    }
    if (isSiddhamScriptExtensionsName(name)) {
        return isUnicodeSiddhamScriptExtensionsCodePoint(code_point);
    }
    if (isSideticScriptExtensionsName(name)) {
        return isUnicodeSideticScriptExtensionsCodePoint(code_point);
    }
    if (isSinhalaScriptExtensionsName(name)) {
        return isUnicodeSinhalaScriptExtensionsCodePoint(code_point);
    }
    if (isSogdianScriptExtensionsName(name)) {
        return isUnicodeSogdianScriptExtensionsCodePoint(code_point);
    }
    if (isSoyomboScriptExtensionsName(name)) {
        return isUnicodeSoyomboScriptExtensionsCodePoint(code_point);
    }
    if (isSundaneseScriptExtensionsName(name)) {
        return isUnicodeSundaneseScriptExtensionsCodePoint(code_point);
    }
    if (isSunuwarScriptExtensionsName(name)) {
        return isUnicodeSunuwarScriptExtensionsCodePoint(code_point);
    }
    if (isSylotiNagriScriptExtensionsName(name)) {
        return isUnicodeSylotiNagriScriptExtensionsCodePoint(code_point);
    }
    if (isSyriacScriptExtensionsName(name)) {
        return isUnicodeSyriacScriptExtensionsCodePoint(code_point);
    }
    if (isTagalogScriptExtensionsName(name)) {
        return isUnicodeTagalogScriptExtensionsCodePoint(code_point);
    }
    if (isTagbanwaScriptExtensionsName(name)) {
        return isUnicodeTagbanwaScriptExtensionsCodePoint(code_point);
    }
    if (isTaiLeScriptExtensionsName(name)) {
        return isUnicodeTaiLeScriptExtensionsCodePoint(code_point);
    }
    if (isTakriScriptExtensionsName(name)) {
        return isUnicodeTakriScriptExtensionsCodePoint(code_point);
    }
    if (isTangutScriptExtensionsName(name)) {
        return isUnicodeTangutScriptExtensionsCodePoint(code_point);
    }
    if (isTeluguScriptExtensionsName(name)) {
        return isUnicodeTeluguScriptExtensionsCodePoint(code_point);
    }
    if (isThaanaScriptExtensionsName(name)) {
        return isUnicodeThaanaScriptExtensionsCodePoint(code_point);
    }
    if (isThaiScriptExtensionsName(name)) {
        return isUnicodeThaiScriptExtensionsCodePoint(code_point);
    }
    if (isTibetanScriptExtensionsName(name)) {
        return isUnicodeTibetanScriptExtensionsCodePoint(code_point);
    }
    if (isTifinaghScriptExtensionsName(name)) {
        return isUnicodeTifinaghScriptExtensionsCodePoint(code_point);
    }
    if (isTirhutaScriptExtensionsName(name)) {
        return isUnicodeTirhutaScriptExtensionsCodePoint(code_point);
    }
    if (isTodhriScriptExtensionsName(name)) {
        return isUnicodeTodhriScriptExtensionsCodePoint(code_point);
    }
    if (isTotoScriptExtensionsName(name)) {
        return isUnicodeTotoScriptExtensionsCodePoint(code_point);
    }
    if (isTuluTigalariScriptExtensionsName(name)) {
        return isUnicodeTuluTigalariScriptExtensionsCodePoint(code_point);
    }
    if (isYezidiScriptExtensionsName(name)) {
        return isUnicodeYezidiScriptExtensionsCodePoint(code_point);
    }
    if (isYiScriptExtensionsName(name)) {
        return isUnicodeYiScriptExtensionsCodePoint(code_point);
    }
    if (isGranthaScriptExtensionsName(name)) {
        return isUnicodeGranthaScriptExtensionsCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "ASCII")) {
        return code_point <= 0x7f;
    }
    if (std.mem.eql(u8, name, "ASCII_Hex_Digit") or
        std.mem.eql(u8, name, "AHex"))
    {
        return code_point <= 0x7f and std.ascii.isHex(@intCast(code_point));
    }
    if (std.mem.eql(u8, name, "Hex_Digit") or
        std.mem.eql(u8, name, "Hex"))
    {
        return isUnicodeHexDigitCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Cased")) return isUnicodeCasedCodePoint(code_point);
    if (std.mem.eql(u8, name, "Dash")) {
        return isUnicodeDashCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Bidi_Mirrored") or std.mem.eql(u8, name, "Bidi_M")) return isUnicodeBidiMirroredCodePoint(code_point);
    if (std.mem.eql(u8, name, "Bidi_Control") or std.mem.eql(u8, name, "Bidi_C")) return isUnicodeBidiControlCodePoint(code_point);
    if (std.mem.eql(u8, name, "Deprecated") or std.mem.eql(u8, name, "Dep")) return isUnicodeDeprecatedCodePoint(code_point);
    if (std.mem.eql(u8, name, "Diacritic") or std.mem.eql(u8, name, "Dia")) return isUnicodeDiacriticCodePoint(code_point);
    if (std.mem.eql(u8, name, "IDS_Binary_Operator") or std.mem.eql(u8, name, "IDSB")) return isUnicodeIdsBinaryOperatorCodePoint(code_point);
    if (std.mem.eql(u8, name, "IDS_Trinary_Operator") or std.mem.eql(u8, name, "IDST")) return isUnicodeIdsTrinaryOperatorCodePoint(code_point);
    if (std.mem.eql(u8, name, "ID_Start") or std.mem.eql(u8, name, "IDS")) {
        const singles = [_]u21{ 0x002118, 0x00212e };
        const ranges = [_][2]u21{
            .{ 0x001885, 0x001886 },
            .{ 0x00309b, 0x00309c },
        };
        if (code_point == 0x002e2f) return false;
        return binaryPropertyCodePointMatches("Letter", code_point) or
            binaryPropertyCodePointMatches("Letter_Number", code_point) or
            codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "ID_Continue") or std.mem.eql(u8, name, "IDC")) {
        return isUnicodeIdContinueCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "XID_Start") or std.mem.eql(u8, name, "XIDS")) {
        const excluded_singles = [_]u21{
            0x00037a, 0x000e33, 0x000eb3, 0x00fe70, 0x00fe72, 0x00fe74,
            0x00fe76, 0x00fe78, 0x00fe7a, 0x00fe7c, 0x00fe7e,
        };
        const excluded_ranges = [_][2]u21{
            .{ 0x00309b, 0x00309c },
            .{ 0x00fc5e, 0x00fc63 },
            .{ 0x00fdfa, 0x00fdfb },
            .{ 0x00ff9e, 0x00ff9f },
        };
        return binaryPropertyCodePointMatches("ID_Start", code_point) and
            !codePointInUnicodeSet(code_point, &excluded_singles, &excluded_ranges);
    }
    if (std.mem.eql(u8, name, "XID_Continue") or std.mem.eql(u8, name, "XIDC")) {
        return isUnicodeXidContinueCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Join_Control") or std.mem.eql(u8, name, "Join_C")) return code_point >= 0x00200c and code_point <= 0x00200d;
    if (std.mem.eql(u8, name, "Radical")) return isUnicodeRadicalCodePoint(code_point);
    if (std.mem.eql(u8, name, "Variation_Selector") or std.mem.eql(u8, name, "VS")) return isUnicodeVariationSelectorCodePoint(code_point);
    if (std.mem.eql(u8, name, "Quotation_Mark") or std.mem.eql(u8, name, "QMark")) return isUnicodeQuotationMarkCodePoint(code_point);
    if (std.mem.eql(u8, name, "Pattern_White_Space") or std.mem.eql(u8, name, "Pat_WS")) return isUnicodePatternWhiteSpaceCodePoint(code_point);
    if (std.mem.eql(u8, name, "White_Space") or std.mem.eql(u8, name, "space")) return isUnicodeWhiteSpaceCodePoint(code_point);
    if (std.mem.eql(u8, name, "Regional_Indicator") or std.mem.eql(u8, name, "RI")) return code_point >= 0x01f1e6 and code_point <= 0x01f1ff;
    if (std.mem.eql(u8, name, "Logical_Order_Exception") or std.mem.eql(u8, name, "LOE")) return isUnicodeLogicalOrderExceptionCodePoint(code_point);
    if (std.mem.eql(u8, name, "Noncharacter_Code_Point") or std.mem.eql(u8, name, "NChar")) return isUnicodeNoncharacterCodePoint(code_point);
    if (std.mem.eql(u8, name, "Pattern_Syntax") or std.mem.eql(u8, name, "Pat_Syn")) return isUnicodePatternSyntaxCodePoint(code_point);
    if (std.mem.eql(u8, name, "Default_Ignorable_Code_Point") or std.mem.eql(u8, name, "DI")) return isUnicodeDefaultIgnorableCodePoint(code_point);
    if (std.mem.eql(u8, name, "Alphabetic") or std.mem.eql(u8, name, "Alpha")) return isUnicodeAlphabeticCodePoint(code_point);
    if (std.mem.eql(u8, name, "Lowercase") or std.mem.eql(u8, name, "Lower")) return isUnicodeLowercaseCodePoint(code_point);
    if (std.mem.eql(u8, name, "Uppercase") or std.mem.eql(u8, name, "Upper")) return isUnicodeUppercaseCodePoint(code_point);
    if (std.mem.eql(u8, name, "Case_Ignorable") or std.mem.eql(u8, name, "CI")) return isUnicodeCaseIgnorableCodePoint(code_point);
    if (std.mem.eql(u8, name, "Changes_When_Casemapped") or std.mem.eql(u8, name, "CWCM")) return isUnicodeChangesWhenCasemappedCodePoint(code_point);
    if (std.mem.eql(u8, name, "Changes_When_Casefolded") or std.mem.eql(u8, name, "CWCF")) return isUnicodeChangesWhenCasefoldedCodePoint(code_point);
    if (std.mem.eql(u8, name, "Changes_When_Lowercased") or std.mem.eql(u8, name, "CWL")) return isUnicodeChangesWhenLowercasedCodePoint(code_point);
    if (std.mem.eql(u8, name, "Changes_When_Titlecased") or std.mem.eql(u8, name, "CWT")) return isUnicodeChangesWhenTitlecasedCodePoint(code_point);
    if (std.mem.eql(u8, name, "Changes_When_Uppercased") or std.mem.eql(u8, name, "CWU")) return isUnicodeChangesWhenUppercasedCodePoint(code_point);
    if (std.mem.eql(u8, name, "Changes_When_NFKC_Casefolded") or std.mem.eql(u8, name, "CWKCF")) return isUnicodeChangesWhenNfkcCasefoldedCodePoint(code_point);
    if (std.mem.eql(u8, name, "Cased_Letter") or
        std.mem.eql(u8, name, "LC") or
        std.mem.eql(u8, name, "General_Category=Cased_Letter") or
        std.mem.eql(u8, name, "General_Category=LC") or
        std.mem.eql(u8, name, "gc=Cased_Letter") or
        std.mem.eql(u8, name, "gc=LC"))
    {
        const singles = [_]u21{
            0x0000b5,
            0x00037f,
            0x000386,
            0x00038c,
            0x0010c7,
            0x0010cd,
            0x001f59,
            0x001f5b,
            0x001f5d,
            0x001fbe,
            0x002102,
            0x002107,
            0x002115,
            0x002124,
            0x002126,
            0x002128,
            0x002139,
            0x00214e,
            0x002d27,
            0x002d2d,
            0x00a7fa,
            0x01d4a2,
            0x01d4bb,
            0x01d546,
        };
        const ranges = [_][2]u21{
            .{ 0x000041, 0x00005a },
            .{ 0x000061, 0x00007a },
            .{ 0x0000c0, 0x0000d6 },
            .{ 0x0000d8, 0x0000f6 },
            .{ 0x0000f8, 0x0001ba },
            .{ 0x0001bc, 0x0001bf },
            .{ 0x0001c4, 0x000293 },
            .{ 0x000296, 0x0002af },
            .{ 0x000370, 0x000373 },
            .{ 0x000376, 0x000377 },
            .{ 0x00037b, 0x00037d },
            .{ 0x000388, 0x00038a },
            .{ 0x00038e, 0x0003a1 },
            .{ 0x0003a3, 0x0003f5 },
            .{ 0x0003f7, 0x000481 },
            .{ 0x00048a, 0x00052f },
            .{ 0x000531, 0x000556 },
            .{ 0x000560, 0x000588 },
            .{ 0x0010a0, 0x0010c5 },
            .{ 0x0010d0, 0x0010fa },
            .{ 0x0010fd, 0x0010ff },
            .{ 0x0013a0, 0x0013f5 },
            .{ 0x0013f8, 0x0013fd },
            .{ 0x001c80, 0x001c8a },
            .{ 0x001c90, 0x001cba },
            .{ 0x001cbd, 0x001cbf },
            .{ 0x001d00, 0x001d2b },
            .{ 0x001d6b, 0x001d77 },
            .{ 0x001d79, 0x001d9a },
            .{ 0x001e00, 0x001f15 },
            .{ 0x001f18, 0x001f1d },
            .{ 0x001f20, 0x001f45 },
            .{ 0x001f48, 0x001f4d },
            .{ 0x001f50, 0x001f57 },
            .{ 0x001f5f, 0x001f7d },
            .{ 0x001f80, 0x001fb4 },
            .{ 0x001fb6, 0x001fbc },
            .{ 0x001fc2, 0x001fc4 },
            .{ 0x001fc6, 0x001fcc },
            .{ 0x001fd0, 0x001fd3 },
            .{ 0x001fd6, 0x001fdb },
            .{ 0x001fe0, 0x001fec },
            .{ 0x001ff2, 0x001ff4 },
            .{ 0x001ff6, 0x001ffc },
            .{ 0x00210a, 0x002113 },
            .{ 0x002119, 0x00211d },
            .{ 0x00212a, 0x00212d },
            .{ 0x00212f, 0x002134 },
            .{ 0x00213c, 0x00213f },
            .{ 0x002145, 0x002149 },
            .{ 0x002183, 0x002184 },
            .{ 0x002c00, 0x002c7b },
            .{ 0x002c7e, 0x002ce4 },
            .{ 0x002ceb, 0x002cee },
            .{ 0x002cf2, 0x002cf3 },
            .{ 0x002d00, 0x002d25 },
            .{ 0x00a640, 0x00a66d },
            .{ 0x00a680, 0x00a69b },
            .{ 0x00a722, 0x00a76f },
            .{ 0x00a771, 0x00a787 },
            .{ 0x00a78b, 0x00a78e },
            .{ 0x00a790, 0x00a7dc },
            .{ 0x00a7f5, 0x00a7f6 },
            .{ 0x00ab30, 0x00ab5a },
            .{ 0x00ab60, 0x00ab68 },
            .{ 0x00ab70, 0x00abbf },
            .{ 0x00fb00, 0x00fb06 },
            .{ 0x00fb13, 0x00fb17 },
            .{ 0x00ff21, 0x00ff3a },
            .{ 0x00ff41, 0x00ff5a },
            .{ 0x010400, 0x01044f },
            .{ 0x0104b0, 0x0104d3 },
            .{ 0x0104d8, 0x0104fb },
            .{ 0x010570, 0x01057a },
            .{ 0x01057c, 0x01058a },
            .{ 0x01058c, 0x010592 },
            .{ 0x010594, 0x010595 },
            .{ 0x010597, 0x0105a1 },
            .{ 0x0105a3, 0x0105b1 },
            .{ 0x0105b3, 0x0105b9 },
            .{ 0x0105bb, 0x0105bc },
            .{ 0x010c80, 0x010cb2 },
            .{ 0x010cc0, 0x010cf2 },
            .{ 0x010d50, 0x010d65 },
            .{ 0x010d70, 0x010d85 },
            .{ 0x0118a0, 0x0118df },
            .{ 0x016e40, 0x016e7f },
            .{ 0x016ea0, 0x016eb8 },
            .{ 0x016ebb, 0x016ed3 },
            .{ 0x01d400, 0x01d454 },
            .{ 0x01d456, 0x01d49c },
            .{ 0x01d49e, 0x01d49f },
            .{ 0x01d4a5, 0x01d4a6 },
            .{ 0x01d4a9, 0x01d4ac },
            .{ 0x01d4ae, 0x01d4b9 },
            .{ 0x01d4bd, 0x01d4c3 },
            .{ 0x01d4c5, 0x01d505 },
            .{ 0x01d507, 0x01d50a },
            .{ 0x01d50d, 0x01d514 },
            .{ 0x01d516, 0x01d51c },
            .{ 0x01d51e, 0x01d539 },
            .{ 0x01d53b, 0x01d53e },
            .{ 0x01d540, 0x01d544 },
            .{ 0x01d54a, 0x01d550 },
            .{ 0x01d552, 0x01d6a5 },
            .{ 0x01d6a8, 0x01d6c0 },
            .{ 0x01d6c2, 0x01d6da },
            .{ 0x01d6dc, 0x01d6fa },
            .{ 0x01d6fc, 0x01d714 },
            .{ 0x01d716, 0x01d734 },
            .{ 0x01d736, 0x01d74e },
            .{ 0x01d750, 0x01d76e },
            .{ 0x01d770, 0x01d788 },
            .{ 0x01d78a, 0x01d7a8 },
            .{ 0x01d7aa, 0x01d7c2 },
            .{ 0x01d7c4, 0x01d7cb },
            .{ 0x01df00, 0x01df09 },
            .{ 0x01df0b, 0x01df1e },
            .{ 0x01df25, 0x01df2a },
            .{ 0x01e900, 0x01e943 },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Letter") or
        std.mem.eql(u8, name, "L") or
        std.mem.eql(u8, name, "General_Category=Letter") or
        std.mem.eql(u8, name, "General_Category=L") or
        std.mem.eql(u8, name, "gc=Letter") or
        std.mem.eql(u8, name, "gc=L"))
    {
        return isUnicodeLetterCategoryCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Lowercase_Letter") or
        std.mem.eql(u8, name, "Ll") or
        std.mem.eql(u8, name, "General_Category=Lowercase_Letter") or
        std.mem.eql(u8, name, "General_Category=Ll") or
        std.mem.eql(u8, name, "gc=Lowercase_Letter") or
        std.mem.eql(u8, name, "gc=Ll"))
    {
        const singles = [_]u21{
            0x0000b5, 0x000101, 0x000103, 0x000105, 0x000107, 0x000109,
            0x00010b, 0x00010d, 0x00010f, 0x000111, 0x000113, 0x000115,
            0x000117, 0x000119, 0x00011b, 0x00011d, 0x00011f, 0x000121,
            0x000123, 0x000125, 0x000127, 0x000129, 0x00012b, 0x00012d,
            0x00012f, 0x000131, 0x000133, 0x000135, 0x00013a, 0x00013c,
            0x00013e, 0x000140, 0x000142, 0x000144, 0x000146, 0x00014b,
            0x00014d, 0x00014f, 0x000151, 0x000153, 0x000155, 0x000157,
            0x000159, 0x00015b, 0x00015d, 0x00015f, 0x000161, 0x000163,
            0x000165, 0x000167, 0x000169, 0x00016b, 0x00016d, 0x00016f,
            0x000171, 0x000173, 0x000175, 0x000177, 0x00017a, 0x00017c,
            0x000183, 0x000185, 0x000188, 0x000192, 0x000195, 0x00019e,
            0x0001a1, 0x0001a3, 0x0001a5, 0x0001a8, 0x0001ad, 0x0001b0,
            0x0001b4, 0x0001b6, 0x0001c6, 0x0001c9, 0x0001cc, 0x0001ce,
            0x0001d0, 0x0001d2, 0x0001d4, 0x0001d6, 0x0001d8, 0x0001da,
            0x0001df, 0x0001e1, 0x0001e3, 0x0001e5, 0x0001e7, 0x0001e9,
            0x0001eb, 0x0001ed, 0x0001f3, 0x0001f5, 0x0001f9, 0x0001fb,
            0x0001fd, 0x0001ff, 0x000201, 0x000203, 0x000205, 0x000207,
            0x000209, 0x00020b, 0x00020d, 0x00020f, 0x000211, 0x000213,
            0x000215, 0x000217, 0x000219, 0x00021b, 0x00021d, 0x00021f,
            0x000221, 0x000223, 0x000225, 0x000227, 0x000229, 0x00022b,
            0x00022d, 0x00022f, 0x000231, 0x00023c, 0x000242, 0x000247,
            0x000249, 0x00024b, 0x00024d, 0x000371, 0x000373, 0x000377,
            0x000390, 0x0003d9, 0x0003db, 0x0003dd, 0x0003df, 0x0003e1,
            0x0003e3, 0x0003e5, 0x0003e7, 0x0003e9, 0x0003eb, 0x0003ed,
            0x0003f5, 0x0003f8, 0x000461, 0x000463, 0x000465, 0x000467,
            0x000469, 0x00046b, 0x00046d, 0x00046f, 0x000471, 0x000473,
            0x000475, 0x000477, 0x000479, 0x00047b, 0x00047d, 0x00047f,
            0x000481, 0x00048b, 0x00048d, 0x00048f, 0x000491, 0x000493,
            0x000495, 0x000497, 0x000499, 0x00049b, 0x00049d, 0x00049f,
            0x0004a1, 0x0004a3, 0x0004a5, 0x0004a7, 0x0004a9, 0x0004ab,
            0x0004ad, 0x0004af, 0x0004b1, 0x0004b3, 0x0004b5, 0x0004b7,
            0x0004b9, 0x0004bb, 0x0004bd, 0x0004bf, 0x0004c2, 0x0004c4,
            0x0004c6, 0x0004c8, 0x0004ca, 0x0004cc, 0x0004d1, 0x0004d3,
            0x0004d5, 0x0004d7, 0x0004d9, 0x0004db, 0x0004dd, 0x0004df,
            0x0004e1, 0x0004e3, 0x0004e5, 0x0004e7, 0x0004e9, 0x0004eb,
            0x0004ed, 0x0004ef, 0x0004f1, 0x0004f3, 0x0004f5, 0x0004f7,
            0x0004f9, 0x0004fb, 0x0004fd, 0x0004ff, 0x000501, 0x000503,
            0x000505, 0x000507, 0x000509, 0x00050b, 0x00050d, 0x00050f,
            0x000511, 0x000513, 0x000515, 0x000517, 0x000519, 0x00051b,
            0x00051d, 0x00051f, 0x000521, 0x000523, 0x000525, 0x000527,
            0x000529, 0x00052b, 0x00052d, 0x00052f, 0x001c8a, 0x001e01,
            0x001e03, 0x001e05, 0x001e07, 0x001e09, 0x001e0b, 0x001e0d,
            0x001e0f, 0x001e11, 0x001e13, 0x001e15, 0x001e17, 0x001e19,
            0x001e1b, 0x001e1d, 0x001e1f, 0x001e21, 0x001e23, 0x001e25,
            0x001e27, 0x001e29, 0x001e2b, 0x001e2d, 0x001e2f, 0x001e31,
            0x001e33, 0x001e35, 0x001e37, 0x001e39, 0x001e3b, 0x001e3d,
            0x001e3f, 0x001e41, 0x001e43, 0x001e45, 0x001e47, 0x001e49,
            0x001e4b, 0x001e4d, 0x001e4f, 0x001e51, 0x001e53, 0x001e55,
            0x001e57, 0x001e59, 0x001e5b, 0x001e5d, 0x001e5f, 0x001e61,
            0x001e63, 0x001e65, 0x001e67, 0x001e69, 0x001e6b, 0x001e6d,
            0x001e6f, 0x001e71, 0x001e73, 0x001e75, 0x001e77, 0x001e79,
            0x001e7b, 0x001e7d, 0x001e7f, 0x001e81, 0x001e83, 0x001e85,
            0x001e87, 0x001e89, 0x001e8b, 0x001e8d, 0x001e8f, 0x001e91,
            0x001e93, 0x001e9f, 0x001ea1, 0x001ea3, 0x001ea5, 0x001ea7,
            0x001ea9, 0x001eab, 0x001ead, 0x001eaf, 0x001eb1, 0x001eb3,
            0x001eb5, 0x001eb7, 0x001eb9, 0x001ebb, 0x001ebd, 0x001ebf,
            0x001ec1, 0x001ec3, 0x001ec5, 0x001ec7, 0x001ec9, 0x001ecb,
            0x001ecd, 0x001ecf, 0x001ed1, 0x001ed3, 0x001ed5, 0x001ed7,
            0x001ed9, 0x001edb, 0x001edd, 0x001edf, 0x001ee1, 0x001ee3,
            0x001ee5, 0x001ee7, 0x001ee9, 0x001eeb, 0x001eed, 0x001eef,
            0x001ef1, 0x001ef3, 0x001ef5, 0x001ef7, 0x001ef9, 0x001efb,
            0x001efd, 0x001fbe, 0x00210a, 0x002113, 0x00212f, 0x002134,
            0x002139, 0x00214e, 0x002184, 0x002c61, 0x002c68, 0x002c6a,
            0x002c6c, 0x002c71, 0x002c81, 0x002c83, 0x002c85, 0x002c87,
            0x002c89, 0x002c8b, 0x002c8d, 0x002c8f, 0x002c91, 0x002c93,
            0x002c95, 0x002c97, 0x002c99, 0x002c9b, 0x002c9d, 0x002c9f,
            0x002ca1, 0x002ca3, 0x002ca5, 0x002ca7, 0x002ca9, 0x002cab,
            0x002cad, 0x002caf, 0x002cb1, 0x002cb3, 0x002cb5, 0x002cb7,
            0x002cb9, 0x002cbb, 0x002cbd, 0x002cbf, 0x002cc1, 0x002cc3,
            0x002cc5, 0x002cc7, 0x002cc9, 0x002ccb, 0x002ccd, 0x002ccf,
            0x002cd1, 0x002cd3, 0x002cd5, 0x002cd7, 0x002cd9, 0x002cdb,
            0x002cdd, 0x002cdf, 0x002ce1, 0x002cec, 0x002cee, 0x002cf3,
            0x002d27, 0x002d2d, 0x00a641, 0x00a643, 0x00a645, 0x00a647,
            0x00a649, 0x00a64b, 0x00a64d, 0x00a64f, 0x00a651, 0x00a653,
            0x00a655, 0x00a657, 0x00a659, 0x00a65b, 0x00a65d, 0x00a65f,
            0x00a661, 0x00a663, 0x00a665, 0x00a667, 0x00a669, 0x00a66b,
            0x00a66d, 0x00a681, 0x00a683, 0x00a685, 0x00a687, 0x00a689,
            0x00a68b, 0x00a68d, 0x00a68f, 0x00a691, 0x00a693, 0x00a695,
            0x00a697, 0x00a699, 0x00a69b, 0x00a723, 0x00a725, 0x00a727,
            0x00a729, 0x00a72b, 0x00a72d, 0x00a733, 0x00a735, 0x00a737,
            0x00a739, 0x00a73b, 0x00a73d, 0x00a73f, 0x00a741, 0x00a743,
            0x00a745, 0x00a747, 0x00a749, 0x00a74b, 0x00a74d, 0x00a74f,
            0x00a751, 0x00a753, 0x00a755, 0x00a757, 0x00a759, 0x00a75b,
            0x00a75d, 0x00a75f, 0x00a761, 0x00a763, 0x00a765, 0x00a767,
            0x00a769, 0x00a76b, 0x00a76d, 0x00a76f, 0x00a77a, 0x00a77c,
            0x00a77f, 0x00a781, 0x00a783, 0x00a785, 0x00a787, 0x00a78c,
            0x00a78e, 0x00a791, 0x00a797, 0x00a799, 0x00a79b, 0x00a79d,
            0x00a79f, 0x00a7a1, 0x00a7a3, 0x00a7a5, 0x00a7a7, 0x00a7a9,
            0x00a7af, 0x00a7b5, 0x00a7b7, 0x00a7b9, 0x00a7bb, 0x00a7bd,
            0x00a7bf, 0x00a7c1, 0x00a7c3, 0x00a7c8, 0x00a7ca, 0x00a7cd,
            0x00a7cf, 0x00a7d1, 0x00a7d3, 0x00a7d5, 0x00a7d7, 0x00a7d9,
            0x00a7db, 0x00a7f6, 0x00a7fa, 0x01d4bb, 0x01d7cb,
        };
        const ranges = [_][2]u21{
            .{ 0x000061, 0x00007a },
            .{ 0x0000df, 0x0000f6 },
            .{ 0x0000f8, 0x0000ff },
            .{ 0x000137, 0x000138 },
            .{ 0x000148, 0x000149 },
            .{ 0x00017e, 0x000180 },
            .{ 0x00018c, 0x00018d },
            .{ 0x000199, 0x00019b },
            .{ 0x0001aa, 0x0001ab },
            .{ 0x0001b9, 0x0001ba },
            .{ 0x0001bd, 0x0001bf },
            .{ 0x0001dc, 0x0001dd },
            .{ 0x0001ef, 0x0001f0 },
            .{ 0x000233, 0x000239 },
            .{ 0x00023f, 0x000240 },
            .{ 0x00024f, 0x000293 },
            .{ 0x000296, 0x0002af },
            .{ 0x00037b, 0x00037d },
            .{ 0x0003ac, 0x0003ce },
            .{ 0x0003d0, 0x0003d1 },
            .{ 0x0003d5, 0x0003d7 },
            .{ 0x0003ef, 0x0003f3 },
            .{ 0x0003fb, 0x0003fc },
            .{ 0x000430, 0x00045f },
            .{ 0x0004ce, 0x0004cf },
            .{ 0x000560, 0x000588 },
            .{ 0x0010d0, 0x0010fa },
            .{ 0x0010fd, 0x0010ff },
            .{ 0x0013f8, 0x0013fd },
            .{ 0x001c80, 0x001c88 },
            .{ 0x001d00, 0x001d2b },
            .{ 0x001d6b, 0x001d77 },
            .{ 0x001d79, 0x001d9a },
            .{ 0x001e95, 0x001e9d },
            .{ 0x001eff, 0x001f07 },
            .{ 0x001f10, 0x001f15 },
            .{ 0x001f20, 0x001f27 },
            .{ 0x001f30, 0x001f37 },
            .{ 0x001f40, 0x001f45 },
            .{ 0x001f50, 0x001f57 },
            .{ 0x001f60, 0x001f67 },
            .{ 0x001f70, 0x001f7d },
            .{ 0x001f80, 0x001f87 },
            .{ 0x001f90, 0x001f97 },
            .{ 0x001fa0, 0x001fa7 },
            .{ 0x001fb0, 0x001fb4 },
            .{ 0x001fb6, 0x001fb7 },
            .{ 0x001fc2, 0x001fc4 },
            .{ 0x001fc6, 0x001fc7 },
            .{ 0x001fd0, 0x001fd3 },
            .{ 0x001fd6, 0x001fd7 },
            .{ 0x001fe0, 0x001fe7 },
            .{ 0x001ff2, 0x001ff4 },
            .{ 0x001ff6, 0x001ff7 },
            .{ 0x00210e, 0x00210f },
            .{ 0x00213c, 0x00213d },
            .{ 0x002146, 0x002149 },
            .{ 0x002c30, 0x002c5f },
            .{ 0x002c65, 0x002c66 },
            .{ 0x002c73, 0x002c74 },
            .{ 0x002c76, 0x002c7b },
            .{ 0x002ce3, 0x002ce4 },
            .{ 0x002d00, 0x002d25 },
            .{ 0x00a72f, 0x00a731 },
            .{ 0x00a771, 0x00a778 },
            .{ 0x00a793, 0x00a795 },
            .{ 0x00ab30, 0x00ab5a },
            .{ 0x00ab60, 0x00ab68 },
            .{ 0x00ab70, 0x00abbf },
            .{ 0x00fb00, 0x00fb06 },
            .{ 0x00fb13, 0x00fb17 },
            .{ 0x00ff41, 0x00ff5a },
            .{ 0x010428, 0x01044f },
            .{ 0x0104d8, 0x0104fb },
            .{ 0x010597, 0x0105a1 },
            .{ 0x0105a3, 0x0105b1 },
            .{ 0x0105b3, 0x0105b9 },
            .{ 0x0105bb, 0x0105bc },
            .{ 0x010cc0, 0x010cf2 },
            .{ 0x010d70, 0x010d85 },
            .{ 0x0118c0, 0x0118df },
            .{ 0x016e60, 0x016e7f },
            .{ 0x016ebb, 0x016ed3 },
            .{ 0x01d41a, 0x01d433 },
            .{ 0x01d44e, 0x01d454 },
            .{ 0x01d456, 0x01d467 },
            .{ 0x01d482, 0x01d49b },
            .{ 0x01d4b6, 0x01d4b9 },
            .{ 0x01d4bd, 0x01d4c3 },
            .{ 0x01d4c5, 0x01d4cf },
            .{ 0x01d4ea, 0x01d503 },
            .{ 0x01d51e, 0x01d537 },
            .{ 0x01d552, 0x01d56b },
            .{ 0x01d586, 0x01d59f },
            .{ 0x01d5ba, 0x01d5d3 },
            .{ 0x01d5ee, 0x01d607 },
            .{ 0x01d622, 0x01d63b },
            .{ 0x01d656, 0x01d66f },
            .{ 0x01d68a, 0x01d6a5 },
            .{ 0x01d6c2, 0x01d6da },
            .{ 0x01d6dc, 0x01d6e1 },
            .{ 0x01d6fc, 0x01d714 },
            .{ 0x01d716, 0x01d71b },
            .{ 0x01d736, 0x01d74e },
            .{ 0x01d750, 0x01d755 },
            .{ 0x01d770, 0x01d788 },
            .{ 0x01d78a, 0x01d78f },
            .{ 0x01d7aa, 0x01d7c2 },
            .{ 0x01d7c4, 0x01d7c9 },
            .{ 0x01df00, 0x01df09 },
            .{ 0x01df0b, 0x01df1e },
            .{ 0x01df25, 0x01df2a },
            .{ 0x01e922, 0x01e943 },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Titlecase_Letter") or
        std.mem.eql(u8, name, "Lt") or
        std.mem.eql(u8, name, "General_Category=Titlecase_Letter") or
        std.mem.eql(u8, name, "General_Category=Lt") or
        std.mem.eql(u8, name, "gc=Titlecase_Letter") or
        std.mem.eql(u8, name, "gc=Lt"))
    {
        return code_point == 0x0001c5 or
            code_point == 0x0001c8 or
            code_point == 0x0001cb or
            code_point == 0x0001f2 or
            code_point == 0x001fbc or
            code_point == 0x001fcc or
            code_point == 0x001ffc or
            (code_point >= 0x001f88 and code_point <= 0x001f8f) or
            (code_point >= 0x001f98 and code_point <= 0x001f9f) or
            (code_point >= 0x001fa8 and code_point <= 0x001faf);
    }
    if (std.mem.eql(u8, name, "Format") or
        std.mem.eql(u8, name, "Cf") or
        std.mem.eql(u8, name, "General_Category=Format") or
        std.mem.eql(u8, name, "General_Category=Cf") or
        std.mem.eql(u8, name, "gc=Format") or
        std.mem.eql(u8, name, "gc=Cf"))
    {
        return code_point == 0x0000ad or
            code_point == 0x00061c or
            code_point == 0x0006dd or
            code_point == 0x00070f or
            code_point == 0x0008e2 or
            code_point == 0x00180e or
            code_point == 0x00feff or
            code_point == 0x0110bd or
            code_point == 0x0110cd or
            code_point == 0x0e0001 or
            (code_point >= 0x000600 and code_point <= 0x000605) or
            (code_point >= 0x000890 and code_point <= 0x000891) or
            (code_point >= 0x00200b and code_point <= 0x00200f) or
            (code_point >= 0x00202a and code_point <= 0x00202e) or
            (code_point >= 0x002060 and code_point <= 0x002064) or
            (code_point >= 0x002066 and code_point <= 0x00206f) or
            (code_point >= 0x00fff9 and code_point <= 0x00fffb) or
            (code_point >= 0x013430 and code_point <= 0x01343f) or
            (code_point >= 0x01bca0 and code_point <= 0x01bca3) or
            (code_point >= 0x01d173 and code_point <= 0x01d17a) or
            (code_point >= 0x0e0020 and code_point <= 0x0e007f);
    }
    if (std.mem.eql(u8, name, "Unassigned") or
        std.mem.eql(u8, name, "Cn") or
        std.mem.eql(u8, name, "General_Category=Unassigned") or
        std.mem.eql(u8, name, "General_Category=Cn") or
        std.mem.eql(u8, name, "gc=Unassigned") or
        std.mem.eql(u8, name, "gc=Cn"))
    {
        return isUnicodeUnassignedCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Other") or
        std.mem.eql(u8, name, "C") or
        std.mem.eql(u8, name, "General_Category=Other") or
        std.mem.eql(u8, name, "General_Category=C") or
        std.mem.eql(u8, name, "gc=Other") or
        std.mem.eql(u8, name, "gc=C"))
    {
        return isUnicodeOtherCategoryCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Decimal_Number") or
        std.mem.eql(u8, name, "Nd") or
        std.mem.eql(u8, name, "digit") or
        std.mem.eql(u8, name, "General_Category=Decimal_Number") or
        std.mem.eql(u8, name, "General_Category=Nd") or
        std.mem.eql(u8, name, "General_Category=digit") or
        std.mem.eql(u8, name, "gc=Decimal_Number") or
        std.mem.eql(u8, name, "gc=Nd") or
        std.mem.eql(u8, name, "gc=digit"))
    {
        const singles = [_]u21{};
        const ranges = [_][2]u21{
            .{ 0x000030, 0x000039 },
            .{ 0x000660, 0x000669 },
            .{ 0x0006f0, 0x0006f9 },
            .{ 0x0007c0, 0x0007c9 },
            .{ 0x000966, 0x00096f },
            .{ 0x0009e6, 0x0009ef },
            .{ 0x000a66, 0x000a6f },
            .{ 0x000ae6, 0x000aef },
            .{ 0x000b66, 0x000b6f },
            .{ 0x000be6, 0x000bef },
            .{ 0x000c66, 0x000c6f },
            .{ 0x000ce6, 0x000cef },
            .{ 0x000d66, 0x000d6f },
            .{ 0x000de6, 0x000def },
            .{ 0x000e50, 0x000e59 },
            .{ 0x000ed0, 0x000ed9 },
            .{ 0x000f20, 0x000f29 },
            .{ 0x001040, 0x001049 },
            .{ 0x001090, 0x001099 },
            .{ 0x0017e0, 0x0017e9 },
            .{ 0x001810, 0x001819 },
            .{ 0x001946, 0x00194f },
            .{ 0x0019d0, 0x0019d9 },
            .{ 0x001a80, 0x001a89 },
            .{ 0x001a90, 0x001a99 },
            .{ 0x001b50, 0x001b59 },
            .{ 0x001bb0, 0x001bb9 },
            .{ 0x001c40, 0x001c49 },
            .{ 0x001c50, 0x001c59 },
            .{ 0x00a620, 0x00a629 },
            .{ 0x00a8d0, 0x00a8d9 },
            .{ 0x00a900, 0x00a909 },
            .{ 0x00a9d0, 0x00a9d9 },
            .{ 0x00a9f0, 0x00a9f9 },
            .{ 0x00aa50, 0x00aa59 },
            .{ 0x00abf0, 0x00abf9 },
            .{ 0x00ff10, 0x00ff19 },
            .{ 0x0104a0, 0x0104a9 },
            .{ 0x010d30, 0x010d39 },
            .{ 0x010d40, 0x010d49 },
            .{ 0x011066, 0x01106f },
            .{ 0x0110f0, 0x0110f9 },
            .{ 0x011136, 0x01113f },
            .{ 0x0111d0, 0x0111d9 },
            .{ 0x0112f0, 0x0112f9 },
            .{ 0x011450, 0x011459 },
            .{ 0x0114d0, 0x0114d9 },
            .{ 0x011650, 0x011659 },
            .{ 0x0116c0, 0x0116c9 },
            .{ 0x0116d0, 0x0116e3 },
            .{ 0x011730, 0x011739 },
            .{ 0x0118e0, 0x0118e9 },
            .{ 0x011950, 0x011959 },
            .{ 0x011bf0, 0x011bf9 },
            .{ 0x011c50, 0x011c59 },
            .{ 0x011d50, 0x011d59 },
            .{ 0x011da0, 0x011da9 },
            .{ 0x011de0, 0x011de9 },
            .{ 0x011f50, 0x011f59 },
            .{ 0x016130, 0x016139 },
            .{ 0x016a60, 0x016a69 },
            .{ 0x016ac0, 0x016ac9 },
            .{ 0x016b50, 0x016b59 },
            .{ 0x016d70, 0x016d79 },
            .{ 0x01ccf0, 0x01ccf9 },
            .{ 0x01d7ce, 0x01d7ff },
            .{ 0x01e140, 0x01e149 },
            .{ 0x01e2f0, 0x01e2f9 },
            .{ 0x01e4f0, 0x01e4f9 },
            .{ 0x01e5f1, 0x01e5fa },
            .{ 0x01e950, 0x01e959 },
            .{ 0x01fbf0, 0x01fbf9 },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Other_Number") or
        std.mem.eql(u8, name, "No") or
        std.mem.eql(u8, name, "General_Category=Other_Number") or
        std.mem.eql(u8, name, "General_Category=No") or
        std.mem.eql(u8, name, "gc=Other_Number") or
        std.mem.eql(u8, name, "gc=No"))
    {
        const singles = [_]u21{
            0x0000b9,
            0x0019da,
            0x002070,
            0x002189,
            0x002cfd,
        };
        const ranges = [_][2]u21{
            .{ 0x0000b2, 0x0000b3 },
            .{ 0x0000bc, 0x0000be },
            .{ 0x0009f4, 0x0009f9 },
            .{ 0x000b72, 0x000b77 },
            .{ 0x000bf0, 0x000bf2 },
            .{ 0x000c78, 0x000c7e },
            .{ 0x000d58, 0x000d5e },
            .{ 0x000d70, 0x000d78 },
            .{ 0x000f2a, 0x000f33 },
            .{ 0x001369, 0x00137c },
            .{ 0x0017f0, 0x0017f9 },
            .{ 0x002074, 0x002079 },
            .{ 0x002080, 0x002089 },
            .{ 0x002150, 0x00215f },
            .{ 0x002460, 0x00249b },
            .{ 0x0024ea, 0x0024ff },
            .{ 0x002776, 0x002793 },
            .{ 0x003192, 0x003195 },
            .{ 0x003220, 0x003229 },
            .{ 0x003248, 0x00324f },
            .{ 0x003251, 0x00325f },
            .{ 0x003280, 0x003289 },
            .{ 0x0032b1, 0x0032bf },
            .{ 0x00a830, 0x00a835 },
            .{ 0x010107, 0x010133 },
            .{ 0x010175, 0x010178 },
            .{ 0x01018a, 0x01018b },
            .{ 0x0102e1, 0x0102fb },
            .{ 0x010320, 0x010323 },
            .{ 0x010858, 0x01085f },
            .{ 0x010879, 0x01087f },
            .{ 0x0108a7, 0x0108af },
            .{ 0x0108fb, 0x0108ff },
            .{ 0x010916, 0x01091b },
            .{ 0x0109bc, 0x0109bd },
            .{ 0x0109c0, 0x0109cf },
            .{ 0x0109d2, 0x0109ff },
            .{ 0x010a40, 0x010a48 },
            .{ 0x010a7d, 0x010a7e },
            .{ 0x010a9d, 0x010a9f },
            .{ 0x010aeb, 0x010aef },
            .{ 0x010b58, 0x010b5f },
            .{ 0x010b78, 0x010b7f },
            .{ 0x010ba9, 0x010baf },
            .{ 0x010cfa, 0x010cff },
            .{ 0x010e60, 0x010e7e },
            .{ 0x010f1d, 0x010f26 },
            .{ 0x010f51, 0x010f54 },
            .{ 0x010fc5, 0x010fcb },
            .{ 0x011052, 0x011065 },
            .{ 0x0111e1, 0x0111f4 },
            .{ 0x01173a, 0x01173b },
            .{ 0x0118ea, 0x0118f2 },
            .{ 0x011c5a, 0x011c6c },
            .{ 0x011fc0, 0x011fd4 },
            .{ 0x016b5b, 0x016b61 },
            .{ 0x016e80, 0x016e96 },
            .{ 0x01d2c0, 0x01d2d3 },
            .{ 0x01d2e0, 0x01d2f3 },
            .{ 0x01d360, 0x01d378 },
            .{ 0x01e8c7, 0x01e8cf },
            .{ 0x01ec71, 0x01ecab },
            .{ 0x01ecad, 0x01ecaf },
            .{ 0x01ecb1, 0x01ecb4 },
            .{ 0x01ed01, 0x01ed2d },
            .{ 0x01ed2f, 0x01ed3d },
            .{ 0x01f100, 0x01f10c },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Number") or
        std.mem.eql(u8, name, "N") or
        std.mem.eql(u8, name, "General_Category=Number") or
        std.mem.eql(u8, name, "General_Category=N") or
        std.mem.eql(u8, name, "gc=Number") or
        std.mem.eql(u8, name, "gc=N"))
    {
        return binaryPropertyCodePointMatches("Decimal_Number", code_point) or
            binaryPropertyCodePointMatches("Letter_Number", code_point) or
            binaryPropertyCodePointMatches("Other_Number", code_point);
    }
    if (std.mem.eql(u8, name, "Math_Symbol") or
        std.mem.eql(u8, name, "Sm") or
        std.mem.eql(u8, name, "General_Category=Math_Symbol") or
        std.mem.eql(u8, name, "General_Category=Sm") or
        std.mem.eql(u8, name, "gc=Math_Symbol") or
        std.mem.eql(u8, name, "gc=Sm"))
    {
        const singles = [_]u21{
            0x00002b,
            0x00007c,
            0x00007e,
            0x0000ac,
            0x0000b1,
            0x0000d7,
            0x0000f7,
            0x0003f6,
            0x002044,
            0x002052,
            0x002118,
            0x00214b,
            0x0021a0,
            0x0021a3,
            0x0021a6,
            0x0021ae,
            0x0021d2,
            0x0021d4,
            0x00237c,
            0x0025b7,
            0x0025c1,
            0x00266f,
            0x00fb29,
            0x00fe62,
            0x00ff0b,
            0x00ff5c,
            0x00ff5e,
            0x00ffe2,
            0x01cef0,
            0x01d6c1,
            0x01d6db,
            0x01d6fb,
            0x01d715,
            0x01d735,
            0x01d74f,
            0x01d76f,
            0x01d789,
            0x01d7a9,
            0x01d7c3,
        };
        const ranges = [_][2]u21{
            .{ 0x00003c, 0x00003e },
            .{ 0x000606, 0x000608 },
            .{ 0x00207a, 0x00207c },
            .{ 0x00208a, 0x00208c },
            .{ 0x002140, 0x002144 },
            .{ 0x002190, 0x002194 },
            .{ 0x00219a, 0x00219b },
            .{ 0x0021ce, 0x0021cf },
            .{ 0x0021f4, 0x0022ff },
            .{ 0x002320, 0x002321 },
            .{ 0x00239b, 0x0023b3 },
            .{ 0x0023dc, 0x0023e1 },
            .{ 0x0025f8, 0x0025ff },
            .{ 0x0027c0, 0x0027c4 },
            .{ 0x0027c7, 0x0027e5 },
            .{ 0x0027f0, 0x0027ff },
            .{ 0x002900, 0x002982 },
            .{ 0x002999, 0x0029d7 },
            .{ 0x0029dc, 0x0029fb },
            .{ 0x0029fe, 0x002aff },
            .{ 0x002b30, 0x002b44 },
            .{ 0x002b47, 0x002b4c },
            .{ 0x00fe64, 0x00fe66 },
            .{ 0x00ff1c, 0x00ff1e },
            .{ 0x00ffe9, 0x00ffec },
            .{ 0x010d8e, 0x010d8f },
            .{ 0x01eef0, 0x01eef1 },
            .{ 0x01f8d0, 0x01f8d8 },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Other_Symbol") or
        std.mem.eql(u8, name, "So") or
        std.mem.eql(u8, name, "General_Category=Other_Symbol") or
        std.mem.eql(u8, name, "General_Category=So") or
        std.mem.eql(u8, name, "gc=Other_Symbol") or
        std.mem.eql(u8, name, "gc=So"))
    {
        const singles = [_]u21{
            0x0000a6,
            0x0000a9,
            0x0000ae,
            0x0000b0,
            0x000482,
            0x0006de,
            0x0006e9,
            0x0007f6,
            0x0009fa,
            0x000b70,
            0x000bfa,
            0x000c7f,
            0x000d4f,
            0x000d79,
            0x000f13,
            0x000f34,
            0x000f36,
            0x000f38,
            0x00166d,
            0x001940,
            0x002114,
            0x002125,
            0x002127,
            0x002129,
            0x00212e,
            0x00214a,
            0x00214f,
            0x0021d3,
            0x003004,
            0x003020,
            0x0031ef,
            0x003250,
            0x00a839,
            0x00ffe4,
            0x00ffe8,
            0x0101a0,
            0x010ac8,
            0x01173f,
            0x016b45,
            0x01bc9c,
            0x01d245,
            0x01e14f,
            0x01ecac,
            0x01ed2e,
            0x01f7f0,
            0x01fac8,
            0x01fbfa,
        };
        const ranges = [_][2]u21{
            .{ 0x00058d, 0x00058e },
            .{ 0x00060e, 0x00060f },
            .{ 0x0006fd, 0x0006fe },
            .{ 0x000bf3, 0x000bf8 },
            .{ 0x000f01, 0x000f03 },
            .{ 0x000f15, 0x000f17 },
            .{ 0x000f1a, 0x000f1f },
            .{ 0x000fbe, 0x000fc5 },
            .{ 0x000fc7, 0x000fcc },
            .{ 0x000fce, 0x000fcf },
            .{ 0x000fd5, 0x000fd8 },
            .{ 0x00109e, 0x00109f },
            .{ 0x001390, 0x001399 },
            .{ 0x0019de, 0x0019ff },
            .{ 0x001b61, 0x001b6a },
            .{ 0x001b74, 0x001b7c },
            .{ 0x002100, 0x002101 },
            .{ 0x002103, 0x002106 },
            .{ 0x002108, 0x002109 },
            .{ 0x002116, 0x002117 },
            .{ 0x00211e, 0x002123 },
            .{ 0x00213a, 0x00213b },
            .{ 0x00214c, 0x00214d },
            .{ 0x00218a, 0x00218b },
            .{ 0x002195, 0x002199 },
            .{ 0x00219c, 0x00219f },
            .{ 0x0021a1, 0x0021a2 },
            .{ 0x0021a4, 0x0021a5 },
            .{ 0x0021a7, 0x0021ad },
            .{ 0x0021af, 0x0021cd },
            .{ 0x0021d0, 0x0021d1 },
            .{ 0x0021d5, 0x0021f3 },
            .{ 0x002300, 0x002307 },
            .{ 0x00230c, 0x00231f },
            .{ 0x002322, 0x002328 },
            .{ 0x00232b, 0x00237b },
            .{ 0x00237d, 0x00239a },
            .{ 0x0023b4, 0x0023db },
            .{ 0x0023e2, 0x002429 },
            .{ 0x002440, 0x00244a },
            .{ 0x00249c, 0x0024e9 },
            .{ 0x002500, 0x0025b6 },
            .{ 0x0025b8, 0x0025c0 },
            .{ 0x0025c2, 0x0025f7 },
            .{ 0x002600, 0x00266e },
            .{ 0x002670, 0x002767 },
            .{ 0x002794, 0x0027bf },
            .{ 0x002800, 0x0028ff },
            .{ 0x002b00, 0x002b2f },
            .{ 0x002b45, 0x002b46 },
            .{ 0x002b4d, 0x002b73 },
            .{ 0x002b76, 0x002bff },
            .{ 0x002ce5, 0x002cea },
            .{ 0x002e50, 0x002e51 },
            .{ 0x002e80, 0x002e99 },
            .{ 0x002e9b, 0x002ef3 },
            .{ 0x002f00, 0x002fd5 },
            .{ 0x002ff0, 0x002fff },
            .{ 0x003012, 0x003013 },
            .{ 0x003036, 0x003037 },
            .{ 0x00303e, 0x00303f },
            .{ 0x003190, 0x003191 },
            .{ 0x003196, 0x00319f },
            .{ 0x0031c0, 0x0031e5 },
            .{ 0x003200, 0x00321e },
            .{ 0x00322a, 0x003247 },
            .{ 0x003260, 0x00327f },
            .{ 0x00328a, 0x0032b0 },
            .{ 0x0032c0, 0x0033ff },
            .{ 0x004dc0, 0x004dff },
            .{ 0x00a490, 0x00a4c6 },
            .{ 0x00a828, 0x00a82b },
            .{ 0x00a836, 0x00a837 },
            .{ 0x00aa77, 0x00aa79 },
            .{ 0x00fbc3, 0x00fbd2 },
            .{ 0x00fd40, 0x00fd4f },
            .{ 0x00fd90, 0x00fd91 },
            .{ 0x00fdc8, 0x00fdcf },
            .{ 0x00fdfd, 0x00fdff },
            .{ 0x00ffed, 0x00ffee },
            .{ 0x00fffc, 0x00fffd },
            .{ 0x010137, 0x01013f },
            .{ 0x010179, 0x010189 },
            .{ 0x01018c, 0x01018e },
            .{ 0x010190, 0x01019c },
            .{ 0x0101d0, 0x0101fc },
            .{ 0x010877, 0x010878 },
            .{ 0x010ed1, 0x010ed8 },
            .{ 0x011fd5, 0x011fdc },
            .{ 0x011fe1, 0x011ff1 },
            .{ 0x016b3c, 0x016b3f },
            .{ 0x01cc00, 0x01ccef },
            .{ 0x01ccfa, 0x01ccfc },
            .{ 0x01cd00, 0x01ceb3 },
            .{ 0x01ceba, 0x01ced0 },
            .{ 0x01cee0, 0x01ceef },
            .{ 0x01cf50, 0x01cfc3 },
            .{ 0x01d000, 0x01d0f5 },
            .{ 0x01d100, 0x01d126 },
            .{ 0x01d129, 0x01d164 },
            .{ 0x01d16a, 0x01d16c },
            .{ 0x01d183, 0x01d184 },
            .{ 0x01d18c, 0x01d1a9 },
            .{ 0x01d1ae, 0x01d1ea },
            .{ 0x01d200, 0x01d241 },
            .{ 0x01d300, 0x01d356 },
            .{ 0x01d800, 0x01d9ff },
            .{ 0x01da37, 0x01da3a },
            .{ 0x01da6d, 0x01da74 },
            .{ 0x01da76, 0x01da83 },
            .{ 0x01da85, 0x01da86 },
            .{ 0x01f000, 0x01f02b },
            .{ 0x01f030, 0x01f093 },
            .{ 0x01f0a0, 0x01f0ae },
            .{ 0x01f0b1, 0x01f0bf },
            .{ 0x01f0c1, 0x01f0cf },
            .{ 0x01f0d1, 0x01f0f5 },
            .{ 0x01f10d, 0x01f1ad },
            .{ 0x01f1e6, 0x01f202 },
            .{ 0x01f210, 0x01f23b },
            .{ 0x01f240, 0x01f248 },
            .{ 0x01f250, 0x01f251 },
            .{ 0x01f260, 0x01f265 },
            .{ 0x01f300, 0x01f3fa },
            .{ 0x01f400, 0x01f6d8 },
            .{ 0x01f6dc, 0x01f6ec },
            .{ 0x01f6f0, 0x01f6fc },
            .{ 0x01f700, 0x01f7d9 },
            .{ 0x01f7e0, 0x01f7eb },
            .{ 0x01f800, 0x01f80b },
            .{ 0x01f810, 0x01f847 },
            .{ 0x01f850, 0x01f859 },
            .{ 0x01f860, 0x01f887 },
            .{ 0x01f890, 0x01f8ad },
            .{ 0x01f8b0, 0x01f8bb },
            .{ 0x01f8c0, 0x01f8c1 },
            .{ 0x01f900, 0x01fa57 },
            .{ 0x01fa60, 0x01fa6d },
            .{ 0x01fa70, 0x01fa7c },
            .{ 0x01fa80, 0x01fa8a },
            .{ 0x01fa8e, 0x01fac6 },
            .{ 0x01facd, 0x01fadc },
            .{ 0x01fadf, 0x01faea },
            .{ 0x01faef, 0x01faf8 },
            .{ 0x01fb00, 0x01fb92 },
            .{ 0x01fb94, 0x01fbef },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Symbol") or
        std.mem.eql(u8, name, "S") or
        std.mem.eql(u8, name, "General_Category=Symbol") or
        std.mem.eql(u8, name, "General_Category=S") or
        std.mem.eql(u8, name, "gc=Symbol") or
        std.mem.eql(u8, name, "gc=S"))
    {
        return isUnicodeSymbolCategoryCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Close_Punctuation") or
        std.mem.eql(u8, name, "Pe") or
        std.mem.eql(u8, name, "General_Category=Close_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pe") or
        std.mem.eql(u8, name, "gc=Close_Punctuation") or
        std.mem.eql(u8, name, "gc=Pe"))
    {
        const singles = [_]u21{
            0x000029,
            0x00005d,
            0x00007d,
            0x000f3b,
            0x000f3d,
            0x00169c,
            0x002046,
            0x00207e,
            0x00208e,
            0x002309,
            0x00230b,
            0x00232a,
            0x002769,
            0x00276b,
            0x00276d,
            0x00276f,
            0x002771,
            0x002773,
            0x002775,
            0x0027c6,
            0x0027e7,
            0x0027e9,
            0x0027eb,
            0x0027ed,
            0x0027ef,
            0x002984,
            0x002986,
            0x002988,
            0x00298a,
            0x00298c,
            0x00298e,
            0x002990,
            0x002992,
            0x002994,
            0x002996,
            0x002998,
            0x0029d9,
            0x0029db,
            0x0029fd,
            0x002e23,
            0x002e25,
            0x002e27,
            0x002e29,
            0x002e56,
            0x002e58,
            0x002e5a,
            0x002e5c,
            0x003009,
            0x00300b,
            0x00300d,
            0x00300f,
            0x003011,
            0x003015,
            0x003017,
            0x003019,
            0x00301b,
            0x00fd3e,
            0x00fe18,
            0x00fe36,
            0x00fe38,
            0x00fe3a,
            0x00fe3c,
            0x00fe3e,
            0x00fe40,
            0x00fe42,
            0x00fe44,
            0x00fe48,
            0x00fe5a,
            0x00fe5c,
            0x00fe5e,
            0x00ff09,
            0x00ff3d,
            0x00ff5d,
            0x00ff60,
            0x00ff63,
        };
        const ranges = [_][2]u21{
            .{ 0x00301e, 0x00301f },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Open_Punctuation") or
        std.mem.eql(u8, name, "Ps") or
        std.mem.eql(u8, name, "General_Category=Open_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Ps") or
        std.mem.eql(u8, name, "gc=Open_Punctuation") or
        std.mem.eql(u8, name, "gc=Ps"))
    {
        const singles = [_]u21{
            0x000028,
            0x00005b,
            0x00007b,
            0x000f3a,
            0x000f3c,
            0x00169b,
            0x00201a,
            0x00201e,
            0x002045,
            0x00207d,
            0x00208d,
            0x002308,
            0x00230a,
            0x002329,
            0x002768,
            0x00276a,
            0x00276c,
            0x00276e,
            0x002770,
            0x002772,
            0x002774,
            0x0027c5,
            0x0027e6,
            0x0027e8,
            0x0027ea,
            0x0027ec,
            0x0027ee,
            0x002983,
            0x002985,
            0x002987,
            0x002989,
            0x00298b,
            0x00298d,
            0x00298f,
            0x002991,
            0x002993,
            0x002995,
            0x002997,
            0x0029d8,
            0x0029da,
            0x0029fc,
            0x002e22,
            0x002e24,
            0x002e26,
            0x002e28,
            0x002e42,
            0x002e55,
            0x002e57,
            0x002e59,
            0x002e5b,
            0x003008,
            0x00300a,
            0x00300c,
            0x00300e,
            0x003010,
            0x003014,
            0x003016,
            0x003018,
            0x00301a,
            0x00301d,
            0x00fd3f,
            0x00fe17,
            0x00fe35,
            0x00fe37,
            0x00fe39,
            0x00fe3b,
            0x00fe3d,
            0x00fe3f,
            0x00fe41,
            0x00fe43,
            0x00fe47,
            0x00fe59,
            0x00fe5b,
            0x00fe5d,
            0x00ff08,
            0x00ff3b,
            0x00ff5b,
            0x00ff5f,
            0x00ff62,
        };
        return codePointInUnicodeSet(code_point, &singles, &.{});
    }
    if (std.mem.eql(u8, name, "Other_Punctuation") or
        std.mem.eql(u8, name, "Po") or
        std.mem.eql(u8, name, "General_Category=Other_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Po") or
        std.mem.eql(u8, name, "gc=Other_Punctuation") or
        std.mem.eql(u8, name, "gc=Po"))
    {
        const singles = [_]u21{
            0x00002a,
            0x00002c,
            0x00005c,
            0x0000a1,
            0x0000a7,
            0x0000bf,
            0x00037e,
            0x000387,
            0x000589,
            0x0005c0,
            0x0005c3,
            0x0005c6,
            0x00061b,
            0x0006d4,
            0x00085e,
            0x000970,
            0x0009fd,
            0x000a76,
            0x000af0,
            0x000c77,
            0x000c84,
            0x000df4,
            0x000e4f,
            0x000f14,
            0x000f85,
            0x0010fb,
            0x00166e,
            0x001cd3,
            0x002053,
            0x002d70,
            0x002e0b,
            0x002e1b,
            0x002e41,
            0x00303d,
            0x0030fb,
            0x00a673,
            0x00a67e,
            0x00a8fc,
            0x00a95f,
            0x00abeb,
            0x00fe19,
            0x00fe30,
            0x00fe68,
            0x00ff0a,
            0x00ff0c,
            0x00ff3c,
            0x00ff61,
            0x01039f,
            0x0103d0,
            0x01056f,
            0x010857,
            0x01091f,
            0x01093f,
            0x010a7f,
            0x010ed0,
            0x0111cd,
            0x0111db,
            0x0112a9,
            0x01145d,
            0x0114c6,
            0x0116b9,
            0x01183b,
            0x0119e2,
            0x011be1,
            0x011fff,
            0x016af5,
            0x016b44,
            0x016fe2,
            0x01bc9f,
            0x01e5ff,
        };
        const ranges = [_][2]u21{
            .{ 0x000021, 0x000023 },
            .{ 0x000025, 0x000027 },
            .{ 0x00002e, 0x00002f },
            .{ 0x00003a, 0x00003b },
            .{ 0x00003f, 0x000040 },
            .{ 0x0000b6, 0x0000b7 },
            .{ 0x00055a, 0x00055f },
            .{ 0x0005f3, 0x0005f4 },
            .{ 0x000609, 0x00060a },
            .{ 0x00060c, 0x00060d },
            .{ 0x00061d, 0x00061f },
            .{ 0x00066a, 0x00066d },
            .{ 0x000700, 0x00070d },
            .{ 0x0007f7, 0x0007f9 },
            .{ 0x000830, 0x00083e },
            .{ 0x000964, 0x000965 },
            .{ 0x000e5a, 0x000e5b },
            .{ 0x000f04, 0x000f12 },
            .{ 0x000fd0, 0x000fd4 },
            .{ 0x000fd9, 0x000fda },
            .{ 0x00104a, 0x00104f },
            .{ 0x001360, 0x001368 },
            .{ 0x0016eb, 0x0016ed },
            .{ 0x001735, 0x001736 },
            .{ 0x0017d4, 0x0017d6 },
            .{ 0x0017d8, 0x0017da },
            .{ 0x001800, 0x001805 },
            .{ 0x001807, 0x00180a },
            .{ 0x001944, 0x001945 },
            .{ 0x001a1e, 0x001a1f },
            .{ 0x001aa0, 0x001aa6 },
            .{ 0x001aa8, 0x001aad },
            .{ 0x001b4e, 0x001b4f },
            .{ 0x001b5a, 0x001b60 },
            .{ 0x001b7d, 0x001b7f },
            .{ 0x001bfc, 0x001bff },
            .{ 0x001c3b, 0x001c3f },
            .{ 0x001c7e, 0x001c7f },
            .{ 0x001cc0, 0x001cc7 },
            .{ 0x002016, 0x002017 },
            .{ 0x002020, 0x002027 },
            .{ 0x002030, 0x002038 },
            .{ 0x00203b, 0x00203e },
            .{ 0x002041, 0x002043 },
            .{ 0x002047, 0x002051 },
            .{ 0x002055, 0x00205e },
            .{ 0x002cf9, 0x002cfc },
            .{ 0x002cfe, 0x002cff },
            .{ 0x002e00, 0x002e01 },
            .{ 0x002e06, 0x002e08 },
            .{ 0x002e0e, 0x002e16 },
            .{ 0x002e18, 0x002e19 },
            .{ 0x002e1e, 0x002e1f },
            .{ 0x002e2a, 0x002e2e },
            .{ 0x002e30, 0x002e39 },
            .{ 0x002e3c, 0x002e3f },
            .{ 0x002e43, 0x002e4f },
            .{ 0x002e52, 0x002e54 },
            .{ 0x003001, 0x003003 },
            .{ 0x00a4fe, 0x00a4ff },
            .{ 0x00a60d, 0x00a60f },
            .{ 0x00a6f2, 0x00a6f7 },
            .{ 0x00a874, 0x00a877 },
            .{ 0x00a8ce, 0x00a8cf },
            .{ 0x00a8f8, 0x00a8fa },
            .{ 0x00a92e, 0x00a92f },
            .{ 0x00a9c1, 0x00a9cd },
            .{ 0x00a9de, 0x00a9df },
            .{ 0x00aa5c, 0x00aa5f },
            .{ 0x00aade, 0x00aadf },
            .{ 0x00aaf0, 0x00aaf1 },
            .{ 0x00fe10, 0x00fe16 },
            .{ 0x00fe45, 0x00fe46 },
            .{ 0x00fe49, 0x00fe4c },
            .{ 0x00fe50, 0x00fe52 },
            .{ 0x00fe54, 0x00fe57 },
            .{ 0x00fe5f, 0x00fe61 },
            .{ 0x00fe6a, 0x00fe6b },
            .{ 0x00ff01, 0x00ff03 },
            .{ 0x00ff05, 0x00ff07 },
            .{ 0x00ff0e, 0x00ff0f },
            .{ 0x00ff1a, 0x00ff1b },
            .{ 0x00ff1f, 0x00ff20 },
            .{ 0x00ff64, 0x00ff65 },
            .{ 0x010100, 0x010102 },
            .{ 0x010a50, 0x010a58 },
            .{ 0x010af0, 0x010af6 },
            .{ 0x010b39, 0x010b3f },
            .{ 0x010b99, 0x010b9c },
            .{ 0x010f55, 0x010f59 },
            .{ 0x010f86, 0x010f89 },
            .{ 0x011047, 0x01104d },
            .{ 0x0110bb, 0x0110bc },
            .{ 0x0110be, 0x0110c1 },
            .{ 0x011140, 0x011143 },
            .{ 0x011174, 0x011175 },
            .{ 0x0111c5, 0x0111c8 },
            .{ 0x0111dd, 0x0111df },
            .{ 0x011238, 0x01123d },
            .{ 0x0113d4, 0x0113d5 },
            .{ 0x0113d7, 0x0113d8 },
            .{ 0x01144b, 0x01144f },
            .{ 0x01145a, 0x01145b },
            .{ 0x0115c1, 0x0115d7 },
            .{ 0x011641, 0x011643 },
            .{ 0x011660, 0x01166c },
            .{ 0x01173c, 0x01173e },
            .{ 0x011944, 0x011946 },
            .{ 0x011a3f, 0x011a46 },
            .{ 0x011a9a, 0x011a9c },
            .{ 0x011a9e, 0x011aa2 },
            .{ 0x011b00, 0x011b09 },
            .{ 0x011c41, 0x011c45 },
            .{ 0x011c70, 0x011c71 },
            .{ 0x011ef7, 0x011ef8 },
            .{ 0x011f43, 0x011f4f },
            .{ 0x012470, 0x012474 },
            .{ 0x012ff1, 0x012ff2 },
            .{ 0x016a6e, 0x016a6f },
            .{ 0x016b37, 0x016b3b },
            .{ 0x016d6d, 0x016d6f },
            .{ 0x016e97, 0x016e9a },
            .{ 0x01da87, 0x01da8b },
            .{ 0x01e95e, 0x01e95f },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Punctuation") or
        std.mem.eql(u8, name, "P") or
        std.mem.eql(u8, name, "punct") or
        std.mem.eql(u8, name, "General_Category=Punctuation") or
        std.mem.eql(u8, name, "General_Category=P") or
        std.mem.eql(u8, name, "General_Category=punct") or
        std.mem.eql(u8, name, "gc=Punctuation") or
        std.mem.eql(u8, name, "gc=P") or
        std.mem.eql(u8, name, "gc=punct"))
    {
        return isUnicodePunctuationCategoryCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Mark") or
        std.mem.eql(u8, name, "Combining_Mark") or
        std.mem.eql(u8, name, "M") or
        std.mem.eql(u8, name, "General_Category=Mark") or
        std.mem.eql(u8, name, "General_Category=Combining_Mark") or
        std.mem.eql(u8, name, "General_Category=M") or
        std.mem.eql(u8, name, "gc=Mark") or
        std.mem.eql(u8, name, "gc=Combining_Mark") or
        std.mem.eql(u8, name, "gc=M"))
    {
        return isUnicodeMarkCategoryCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Nonspacing_Mark") or
        std.mem.eql(u8, name, "Mn") or
        std.mem.eql(u8, name, "General_Category=Nonspacing_Mark") or
        std.mem.eql(u8, name, "General_Category=Mn") or
        std.mem.eql(u8, name, "gc=Nonspacing_Mark") or
        std.mem.eql(u8, name, "gc=Mn"))
    {
        const singles = [_]u21{
            0x0005bf, 0x0005c7, 0x000670, 0x000711, 0x0007fd, 0x00093a,
            0x00093c, 0x00094d, 0x000981, 0x0009bc, 0x0009cd, 0x0009fe,
            0x000a3c, 0x000a51, 0x000a75, 0x000abc, 0x000acd, 0x000b01,
            0x000b3c, 0x000b3f, 0x000b4d, 0x000b82, 0x000bc0, 0x000bcd,
            0x000c00, 0x000c04, 0x000c3c, 0x000c81, 0x000cbc, 0x000cbf,
            0x000cc6, 0x000d4d, 0x000d81, 0x000dca, 0x000dd6, 0x000e31,
            0x000eb1, 0x000f35, 0x000f37, 0x000f39, 0x000fc6, 0x001082,
            0x00108d, 0x00109d, 0x0017c6, 0x0017dd, 0x00180f, 0x0018a9,
            0x001932, 0x001a1b, 0x001a56, 0x001a60, 0x001a62, 0x001a7f,
            0x001b34, 0x001b3c, 0x001b42, 0x001be6, 0x001bed, 0x001ced,
            0x001cf4, 0x0020e1, 0x002d7f, 0x00a66f, 0x00a802, 0x00a806,
            0x00a80b, 0x00a82c, 0x00a8ff, 0x00a9b3, 0x00a9e5, 0x00aa43,
            0x00aa4c, 0x00aa7c, 0x00aab0, 0x00aac1, 0x00aaf6, 0x00abe5,
            0x00abe8, 0x00abed, 0x00fb1e, 0x0101fd, 0x0102e0, 0x010a3f,
            0x011001, 0x011070, 0x0110c2, 0x011173, 0x0111cf, 0x011234,
            0x01123e, 0x011241, 0x0112df, 0x011340, 0x0113ce, 0x0113d0,
            0x0113d2, 0x011446, 0x01145e, 0x0114ba, 0x01163d, 0x0116ab,
            0x0116ad, 0x0116b7, 0x01171d, 0x01171f, 0x01193e, 0x011943,
            0x0119e0, 0x011a47, 0x011b60, 0x011b66, 0x011c3f, 0x011d3a,
            0x011d47, 0x011d95, 0x011d97, 0x011f40, 0x011f42, 0x011f5a,
            0x013440, 0x016f4f, 0x016fe4, 0x01da75, 0x01da84, 0x01e08f,
            0x01e2ae, 0x01e6e3, 0x01e6e6, 0x01e6f5,
        };
        const ranges = [_][2]u21{
            .{ 0x000300, 0x00036f }, .{ 0x000483, 0x000487 }, .{ 0x000591, 0x0005bd },
            .{ 0x0005c1, 0x0005c2 }, .{ 0x0005c4, 0x0005c5 }, .{ 0x000610, 0x00061a },
            .{ 0x00064b, 0x00065f }, .{ 0x0006d6, 0x0006dc }, .{ 0x0006df, 0x0006e4 },
            .{ 0x0006e7, 0x0006e8 }, .{ 0x0006ea, 0x0006ed }, .{ 0x000730, 0x00074a },
            .{ 0x0007a6, 0x0007b0 }, .{ 0x0007eb, 0x0007f3 }, .{ 0x000816, 0x000819 },
            .{ 0x00081b, 0x000823 }, .{ 0x000825, 0x000827 }, .{ 0x000829, 0x00082d },
            .{ 0x000859, 0x00085b }, .{ 0x000897, 0x00089f }, .{ 0x0008ca, 0x0008e1 },
            .{ 0x0008e3, 0x000902 }, .{ 0x000941, 0x000948 }, .{ 0x000951, 0x000957 },
            .{ 0x000962, 0x000963 }, .{ 0x0009c1, 0x0009c4 }, .{ 0x0009e2, 0x0009e3 },
            .{ 0x000a01, 0x000a02 }, .{ 0x000a41, 0x000a42 }, .{ 0x000a47, 0x000a48 },
            .{ 0x000a4b, 0x000a4d }, .{ 0x000a70, 0x000a71 }, .{ 0x000a81, 0x000a82 },
            .{ 0x000ac1, 0x000ac5 }, .{ 0x000ac7, 0x000ac8 }, .{ 0x000ae2, 0x000ae3 },
            .{ 0x000afa, 0x000aff }, .{ 0x000b41, 0x000b44 }, .{ 0x000b55, 0x000b56 },
            .{ 0x000b62, 0x000b63 }, .{ 0x000c3e, 0x000c40 }, .{ 0x000c46, 0x000c48 },
            .{ 0x000c4a, 0x000c4d }, .{ 0x000c55, 0x000c56 }, .{ 0x000c62, 0x000c63 },
            .{ 0x000ccc, 0x000ccd }, .{ 0x000ce2, 0x000ce3 }, .{ 0x000d00, 0x000d01 },
            .{ 0x000d3b, 0x000d3c }, .{ 0x000d41, 0x000d44 }, .{ 0x000d62, 0x000d63 },
            .{ 0x000dd2, 0x000dd4 }, .{ 0x000e34, 0x000e3a }, .{ 0x000e47, 0x000e4e },
            .{ 0x000eb4, 0x000ebc }, .{ 0x000ec8, 0x000ece }, .{ 0x000f18, 0x000f19 },
            .{ 0x000f71, 0x000f7e }, .{ 0x000f80, 0x000f84 }, .{ 0x000f86, 0x000f87 },
            .{ 0x000f8d, 0x000f97 }, .{ 0x000f99, 0x000fbc }, .{ 0x00102d, 0x001030 },
            .{ 0x001032, 0x001037 }, .{ 0x001039, 0x00103a }, .{ 0x00103d, 0x00103e },
            .{ 0x001058, 0x001059 }, .{ 0x00105e, 0x001060 }, .{ 0x001071, 0x001074 },
            .{ 0x001085, 0x001086 }, .{ 0x00135d, 0x00135f }, .{ 0x001712, 0x001714 },
            .{ 0x001732, 0x001733 }, .{ 0x001752, 0x001753 }, .{ 0x001772, 0x001773 },
            .{ 0x0017b4, 0x0017b5 }, .{ 0x0017b7, 0x0017bd }, .{ 0x0017c9, 0x0017d3 },
            .{ 0x00180b, 0x00180d }, .{ 0x001885, 0x001886 }, .{ 0x001920, 0x001922 },
            .{ 0x001927, 0x001928 }, .{ 0x001939, 0x00193b }, .{ 0x001a17, 0x001a18 },
            .{ 0x001a58, 0x001a5e }, .{ 0x001a65, 0x001a6c }, .{ 0x001a73, 0x001a7c },
            .{ 0x001ab0, 0x001abd }, .{ 0x001abf, 0x001add }, .{ 0x001ae0, 0x001aeb },
            .{ 0x001b00, 0x001b03 }, .{ 0x001b36, 0x001b3a }, .{ 0x001b6b, 0x001b73 },
            .{ 0x001b80, 0x001b81 }, .{ 0x001ba2, 0x001ba5 }, .{ 0x001ba8, 0x001ba9 },
            .{ 0x001bab, 0x001bad }, .{ 0x001be8, 0x001be9 }, .{ 0x001bef, 0x001bf1 },
            .{ 0x001c2c, 0x001c33 }, .{ 0x001c36, 0x001c37 }, .{ 0x001cd0, 0x001cd2 },
            .{ 0x001cd4, 0x001ce0 }, .{ 0x001ce2, 0x001ce8 }, .{ 0x001cf8, 0x001cf9 },
            .{ 0x001dc0, 0x001dff }, .{ 0x0020d0, 0x0020dc }, .{ 0x0020e5, 0x0020f0 },
            .{ 0x002cef, 0x002cf1 }, .{ 0x002de0, 0x002dff }, .{ 0x00302a, 0x00302d },
            .{ 0x003099, 0x00309a }, .{ 0x00a674, 0x00a67d }, .{ 0x00a69e, 0x00a69f },
            .{ 0x00a6f0, 0x00a6f1 }, .{ 0x00a825, 0x00a826 }, .{ 0x00a8c4, 0x00a8c5 },
            .{ 0x00a8e0, 0x00a8f1 }, .{ 0x00a926, 0x00a92d }, .{ 0x00a947, 0x00a951 },
            .{ 0x00a980, 0x00a982 }, .{ 0x00a9b6, 0x00a9b9 }, .{ 0x00a9bc, 0x00a9bd },
            .{ 0x00aa29, 0x00aa2e }, .{ 0x00aa31, 0x00aa32 }, .{ 0x00aa35, 0x00aa36 },
            .{ 0x00aab2, 0x00aab4 }, .{ 0x00aab7, 0x00aab8 }, .{ 0x00aabe, 0x00aabf },
            .{ 0x00aaec, 0x00aaed }, .{ 0x00fe00, 0x00fe0f }, .{ 0x00fe20, 0x00fe2f },
            .{ 0x010376, 0x01037a }, .{ 0x010a01, 0x010a03 }, .{ 0x010a05, 0x010a06 },
            .{ 0x010a0c, 0x010a0f }, .{ 0x010a38, 0x010a3a }, .{ 0x010ae5, 0x010ae6 },
            .{ 0x010d24, 0x010d27 }, .{ 0x010d69, 0x010d6d }, .{ 0x010eab, 0x010eac },
            .{ 0x010efa, 0x010eff }, .{ 0x010f46, 0x010f50 }, .{ 0x010f82, 0x010f85 },
            .{ 0x011038, 0x011046 }, .{ 0x011073, 0x011074 }, .{ 0x01107f, 0x011081 },
            .{ 0x0110b3, 0x0110b6 }, .{ 0x0110b9, 0x0110ba }, .{ 0x011100, 0x011102 },
            .{ 0x011127, 0x01112b }, .{ 0x01112d, 0x011134 }, .{ 0x011180, 0x011181 },
            .{ 0x0111b6, 0x0111be }, .{ 0x0111c9, 0x0111cc }, .{ 0x01122f, 0x011231 },
            .{ 0x011236, 0x011237 }, .{ 0x0112e3, 0x0112ea }, .{ 0x011300, 0x011301 },
            .{ 0x01133b, 0x01133c }, .{ 0x011366, 0x01136c }, .{ 0x011370, 0x011374 },
            .{ 0x0113bb, 0x0113c0 }, .{ 0x0113e1, 0x0113e2 }, .{ 0x011438, 0x01143f },
            .{ 0x011442, 0x011444 }, .{ 0x0114b3, 0x0114b8 }, .{ 0x0114bf, 0x0114c0 },
            .{ 0x0114c2, 0x0114c3 }, .{ 0x0115b2, 0x0115b5 }, .{ 0x0115bc, 0x0115bd },
            .{ 0x0115bf, 0x0115c0 }, .{ 0x0115dc, 0x0115dd }, .{ 0x011633, 0x01163a },
            .{ 0x01163f, 0x011640 }, .{ 0x0116b0, 0x0116b5 }, .{ 0x011722, 0x011725 },
            .{ 0x011727, 0x01172b }, .{ 0x01182f, 0x011837 }, .{ 0x011839, 0x01183a },
            .{ 0x01193b, 0x01193c }, .{ 0x0119d4, 0x0119d7 }, .{ 0x0119da, 0x0119db },
            .{ 0x011a01, 0x011a0a }, .{ 0x011a33, 0x011a38 }, .{ 0x011a3b, 0x011a3e },
            .{ 0x011a51, 0x011a56 }, .{ 0x011a59, 0x011a5b }, .{ 0x011a8a, 0x011a96 },
            .{ 0x011a98, 0x011a99 }, .{ 0x011b62, 0x011b64 }, .{ 0x011c30, 0x011c36 },
            .{ 0x011c38, 0x011c3d }, .{ 0x011c92, 0x011ca7 }, .{ 0x011caa, 0x011cb0 },
            .{ 0x011cb2, 0x011cb3 }, .{ 0x011cb5, 0x011cb6 }, .{ 0x011d31, 0x011d36 },
            .{ 0x011d3c, 0x011d3d }, .{ 0x011d3f, 0x011d45 }, .{ 0x011d90, 0x011d91 },
            .{ 0x011ef3, 0x011ef4 }, .{ 0x011f00, 0x011f01 }, .{ 0x011f36, 0x011f3a },
            .{ 0x013447, 0x013455 }, .{ 0x01611e, 0x016129 }, .{ 0x01612d, 0x01612f },
            .{ 0x016af0, 0x016af4 }, .{ 0x016b30, 0x016b36 }, .{ 0x016f8f, 0x016f92 },
            .{ 0x01bc9d, 0x01bc9e }, .{ 0x01cf00, 0x01cf2d }, .{ 0x01cf30, 0x01cf46 },
            .{ 0x01d167, 0x01d169 }, .{ 0x01d17b, 0x01d182 }, .{ 0x01d185, 0x01d18b },
            .{ 0x01d1aa, 0x01d1ad }, .{ 0x01d242, 0x01d244 }, .{ 0x01da00, 0x01da36 },
            .{ 0x01da3b, 0x01da6c }, .{ 0x01da9b, 0x01da9f }, .{ 0x01daa1, 0x01daaf },
            .{ 0x01e000, 0x01e006 }, .{ 0x01e008, 0x01e018 }, .{ 0x01e01b, 0x01e021 },
            .{ 0x01e023, 0x01e024 }, .{ 0x01e026, 0x01e02a }, .{ 0x01e130, 0x01e136 },
            .{ 0x01e2ec, 0x01e2ef }, .{ 0x01e4ec, 0x01e4ef }, .{ 0x01e5ee, 0x01e5ef },
            .{ 0x01e6ee, 0x01e6ef }, .{ 0x01e8d0, 0x01e8d6 }, .{ 0x01e944, 0x01e94a },
            .{ 0x0e0100, 0x0e01ef },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Spacing_Mark") or
        std.mem.eql(u8, name, "Mc") or
        std.mem.eql(u8, name, "General_Category=Spacing_Mark") or
        std.mem.eql(u8, name, "General_Category=Mc") or
        std.mem.eql(u8, name, "gc=Spacing_Mark") or
        std.mem.eql(u8, name, "gc=Mc"))
    {
        const singles = [_]u21{
            0x000903,
            0x00093b,
            0x0009d7,
            0x000a03,
            0x000a83,
            0x000ac9,
            0x000b3e,
            0x000b40,
            0x000b57,
            0x000bd7,
            0x000cbe,
            0x000cf3,
            0x000d57,
            0x000f7f,
            0x001031,
            0x001038,
            0x00108f,
            0x001715,
            0x001734,
            0x0017b6,
            0x001a55,
            0x001a57,
            0x001a61,
            0x001b04,
            0x001b35,
            0x001b3b,
            0x001b82,
            0x001ba1,
            0x001baa,
            0x001be7,
            0x001bee,
            0x001ce1,
            0x001cf7,
            0x00a827,
            0x00a983,
            0x00aa4d,
            0x00aa7b,
            0x00aa7d,
            0x00aaeb,
            0x00aaf5,
            0x00abec,
            0x011000,
            0x011002,
            0x011082,
            0x01112c,
            0x011182,
            0x0111ce,
            0x011235,
            0x011357,
            0x0113c2,
            0x0113c5,
            0x0113cf,
            0x011445,
            0x0114b9,
            0x0114c1,
            0x0115be,
            0x01163e,
            0x0116ac,
            0x0116b6,
            0x01171e,
            0x011726,
            0x011838,
            0x01193d,
            0x011940,
            0x011942,
            0x0119e4,
            0x011a39,
            0x011a97,
            0x011b61,
            0x011b65,
            0x011b67,
            0x011c2f,
            0x011c3e,
            0x011ca9,
            0x011cb1,
            0x011cb4,
            0x011d96,
            0x011f03,
            0x011f41,
        };
        const ranges = [_][2]u21{
            .{ 0x00093e, 0x000940 },
            .{ 0x000949, 0x00094c },
            .{ 0x00094e, 0x00094f },
            .{ 0x000982, 0x000983 },
            .{ 0x0009be, 0x0009c0 },
            .{ 0x0009c7, 0x0009c8 },
            .{ 0x0009cb, 0x0009cc },
            .{ 0x000a3e, 0x000a40 },
            .{ 0x000abe, 0x000ac0 },
            .{ 0x000acb, 0x000acc },
            .{ 0x000b02, 0x000b03 },
            .{ 0x000b47, 0x000b48 },
            .{ 0x000b4b, 0x000b4c },
            .{ 0x000bbe, 0x000bbf },
            .{ 0x000bc1, 0x000bc2 },
            .{ 0x000bc6, 0x000bc8 },
            .{ 0x000bca, 0x000bcc },
            .{ 0x000c01, 0x000c03 },
            .{ 0x000c41, 0x000c44 },
            .{ 0x000c82, 0x000c83 },
            .{ 0x000cc0, 0x000cc4 },
            .{ 0x000cc7, 0x000cc8 },
            .{ 0x000cca, 0x000ccb },
            .{ 0x000cd5, 0x000cd6 },
            .{ 0x000d02, 0x000d03 },
            .{ 0x000d3e, 0x000d40 },
            .{ 0x000d46, 0x000d48 },
            .{ 0x000d4a, 0x000d4c },
            .{ 0x000d82, 0x000d83 },
            .{ 0x000dcf, 0x000dd1 },
            .{ 0x000dd8, 0x000ddf },
            .{ 0x000df2, 0x000df3 },
            .{ 0x000f3e, 0x000f3f },
            .{ 0x00102b, 0x00102c },
            .{ 0x00103b, 0x00103c },
            .{ 0x001056, 0x001057 },
            .{ 0x001062, 0x001064 },
            .{ 0x001067, 0x00106d },
            .{ 0x001083, 0x001084 },
            .{ 0x001087, 0x00108c },
            .{ 0x00109a, 0x00109c },
            .{ 0x0017be, 0x0017c5 },
            .{ 0x0017c7, 0x0017c8 },
            .{ 0x001923, 0x001926 },
            .{ 0x001929, 0x00192b },
            .{ 0x001930, 0x001931 },
            .{ 0x001933, 0x001938 },
            .{ 0x001a19, 0x001a1a },
            .{ 0x001a63, 0x001a64 },
            .{ 0x001a6d, 0x001a72 },
            .{ 0x001b3d, 0x001b41 },
            .{ 0x001b43, 0x001b44 },
            .{ 0x001ba6, 0x001ba7 },
            .{ 0x001bea, 0x001bec },
            .{ 0x001bf2, 0x001bf3 },
            .{ 0x001c24, 0x001c2b },
            .{ 0x001c34, 0x001c35 },
            .{ 0x00302e, 0x00302f },
            .{ 0x00a823, 0x00a824 },
            .{ 0x00a880, 0x00a881 },
            .{ 0x00a8b4, 0x00a8c3 },
            .{ 0x00a952, 0x00a953 },
            .{ 0x00a9b4, 0x00a9b5 },
            .{ 0x00a9ba, 0x00a9bb },
            .{ 0x00a9be, 0x00a9c0 },
            .{ 0x00aa2f, 0x00aa30 },
            .{ 0x00aa33, 0x00aa34 },
            .{ 0x00aaee, 0x00aaef },
            .{ 0x00abe3, 0x00abe4 },
            .{ 0x00abe6, 0x00abe7 },
            .{ 0x00abe9, 0x00abea },
            .{ 0x0110b0, 0x0110b2 },
            .{ 0x0110b7, 0x0110b8 },
            .{ 0x011145, 0x011146 },
            .{ 0x0111b3, 0x0111b5 },
            .{ 0x0111bf, 0x0111c0 },
            .{ 0x01122c, 0x01122e },
            .{ 0x011232, 0x011233 },
            .{ 0x0112e0, 0x0112e2 },
            .{ 0x011302, 0x011303 },
            .{ 0x01133e, 0x01133f },
            .{ 0x011341, 0x011344 },
            .{ 0x011347, 0x011348 },
            .{ 0x01134b, 0x01134d },
            .{ 0x011362, 0x011363 },
            .{ 0x0113b8, 0x0113ba },
            .{ 0x0113c7, 0x0113ca },
            .{ 0x0113cc, 0x0113cd },
            .{ 0x011435, 0x011437 },
            .{ 0x011440, 0x011441 },
            .{ 0x0114b0, 0x0114b2 },
            .{ 0x0114bb, 0x0114be },
            .{ 0x0115af, 0x0115b1 },
            .{ 0x0115b8, 0x0115bb },
            .{ 0x011630, 0x011632 },
            .{ 0x01163b, 0x01163c },
            .{ 0x0116ae, 0x0116af },
            .{ 0x011720, 0x011721 },
            .{ 0x01182c, 0x01182e },
            .{ 0x011930, 0x011935 },
            .{ 0x011937, 0x011938 },
            .{ 0x0119d1, 0x0119d3 },
            .{ 0x0119dc, 0x0119df },
            .{ 0x011a57, 0x011a58 },
            .{ 0x011d8a, 0x011d8e },
            .{ 0x011d93, 0x011d94 },
            .{ 0x011ef5, 0x011ef6 },
            .{ 0x011f34, 0x011f35 },
            .{ 0x011f3e, 0x011f3f },
            .{ 0x01612a, 0x01612c },
            .{ 0x016f51, 0x016f87 },
            .{ 0x016ff0, 0x016ff1 },
            .{ 0x01d165, 0x01d166 },
            .{ 0x01d16d, 0x01d172 },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Modifier_Letter") or
        std.mem.eql(u8, name, "Lm") or
        std.mem.eql(u8, name, "General_Category=Modifier_Letter") or
        std.mem.eql(u8, name, "General_Category=Lm") or
        std.mem.eql(u8, name, "gc=Modifier_Letter") or
        std.mem.eql(u8, name, "gc=Lm"))
    {
        const singles = [_]u21{
            0x0002ec,
            0x0002ee,
            0x000374,
            0x00037a,
            0x000559,
            0x000640,
            0x0007fa,
            0x00081a,
            0x000824,
            0x000828,
            0x0008c9,
            0x000971,
            0x000e46,
            0x000ec6,
            0x0010fc,
            0x0017d7,
            0x001843,
            0x001aa7,
            0x001d78,
            0x002071,
            0x00207f,
            0x002d6f,
            0x002e2f,
            0x003005,
            0x00303b,
            0x00a015,
            0x00a60c,
            0x00a67f,
            0x00a770,
            0x00a788,
            0x00a9cf,
            0x00a9e6,
            0x00aa70,
            0x00aadd,
            0x00ab69,
            0x00ff70,
            0x010d4e,
            0x010d6f,
            0x010ec5,
            0x011dd9,
            0x016fe3,
            0x01e4eb,
            0x01e6ff,
            0x01e94b,
        };
        const ranges = [_][2]u21{
            .{ 0x0002b0, 0x0002c1 },
            .{ 0x0002c6, 0x0002d1 },
            .{ 0x0002e0, 0x0002e4 },
            .{ 0x0006e5, 0x0006e6 },
            .{ 0x0007f4, 0x0007f5 },
            .{ 0x001c78, 0x001c7d },
            .{ 0x001d2c, 0x001d6a },
            .{ 0x001d9b, 0x001dbf },
            .{ 0x002090, 0x00209c },
            .{ 0x002c7c, 0x002c7d },
            .{ 0x003031, 0x003035 },
            .{ 0x00309d, 0x00309e },
            .{ 0x0030fc, 0x0030fe },
            .{ 0x00a4f8, 0x00a4fd },
            .{ 0x00a69c, 0x00a69d },
            .{ 0x00a717, 0x00a71f },
            .{ 0x00a7f1, 0x00a7f4 },
            .{ 0x00a7f8, 0x00a7f9 },
            .{ 0x00aaf3, 0x00aaf4 },
            .{ 0x00ab5c, 0x00ab5f },
            .{ 0x00ff9e, 0x00ff9f },
            .{ 0x010780, 0x010785 },
            .{ 0x010787, 0x0107b0 },
            .{ 0x0107b2, 0x0107ba },
            .{ 0x016b40, 0x016b43 },
            .{ 0x016d40, 0x016d42 },
            .{ 0x016d6b, 0x016d6c },
            .{ 0x016f93, 0x016f9f },
            .{ 0x016fe0, 0x016fe1 },
            .{ 0x016ff2, 0x016ff3 },
            .{ 0x01aff0, 0x01aff3 },
            .{ 0x01aff5, 0x01affb },
            .{ 0x01affd, 0x01affe },
            .{ 0x01e030, 0x01e06d },
            .{ 0x01e137, 0x01e13d },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Control") or
        std.mem.eql(u8, name, "Cc") or
        std.mem.eql(u8, name, "cntrl") or
        std.mem.eql(u8, name, "General_Category=Control") or
        std.mem.eql(u8, name, "General_Category=Cc") or
        std.mem.eql(u8, name, "General_Category=cntrl") or
        std.mem.eql(u8, name, "gc=Control") or
        std.mem.eql(u8, name, "gc=Cc") or
        std.mem.eql(u8, name, "gc=cntrl"))
    {
        return isUnicodeControlCategoryCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Connector_Punctuation") or
        std.mem.eql(u8, name, "Pc") or
        std.mem.eql(u8, name, "General_Category=Connector_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pc") or
        std.mem.eql(u8, name, "gc=Connector_Punctuation") or
        std.mem.eql(u8, name, "gc=Pc"))
    {
        return code_point == 0x00005f or
            code_point == 0x002054 or
            code_point == 0x00ff3f or
            (code_point >= 0x00203f and code_point <= 0x002040) or
            (code_point >= 0x00fe33 and code_point <= 0x00fe34) or
            (code_point >= 0x00fe4d and code_point <= 0x00fe4f);
    }
    if (std.mem.eql(u8, name, "Letter_Number") or
        std.mem.eql(u8, name, "Nl") or
        std.mem.eql(u8, name, "General_Category=Letter_Number") or
        std.mem.eql(u8, name, "General_Category=Nl") or
        std.mem.eql(u8, name, "gc=Letter_Number") or
        std.mem.eql(u8, name, "gc=Nl"))
    {
        return code_point == 0x003007 or
            code_point == 0x010341 or
            code_point == 0x01034a or
            (code_point >= 0x0016ee and code_point <= 0x0016f0) or
            (code_point >= 0x002160 and code_point <= 0x002182) or
            (code_point >= 0x002185 and code_point <= 0x002188) or
            (code_point >= 0x003021 and code_point <= 0x003029) or
            (code_point >= 0x003038 and code_point <= 0x00303a) or
            (code_point >= 0x00a6e6 and code_point <= 0x00a6ef) or
            (code_point >= 0x010140 and code_point <= 0x010174) or
            (code_point >= 0x0103d1 and code_point <= 0x0103d5) or
            (code_point >= 0x012400 and code_point <= 0x01246e) or
            (code_point >= 0x016ff4 and code_point <= 0x016ff6);
    }
    if (std.mem.eql(u8, name, "Separator") or
        std.mem.eql(u8, name, "Z") or
        std.mem.eql(u8, name, "General_Category=Separator") or
        std.mem.eql(u8, name, "General_Category=Z") or
        std.mem.eql(u8, name, "gc=Separator") or
        std.mem.eql(u8, name, "gc=Z"))
    {
        return code_point == 0x000020 or
            code_point == 0x0000a0 or
            code_point == 0x001680 or
            code_point == 0x00202f or
            code_point == 0x00205f or
            code_point == 0x003000 or
            (code_point >= 0x002000 and code_point <= 0x00200a) or
            (code_point >= 0x002028 and code_point <= 0x002029);
    }
    if (std.mem.eql(u8, name, "Line_Separator") or
        std.mem.eql(u8, name, "Zl") or
        std.mem.eql(u8, name, "General_Category=Line_Separator") or
        std.mem.eql(u8, name, "General_Category=Zl") or
        std.mem.eql(u8, name, "gc=Line_Separator") or
        std.mem.eql(u8, name, "gc=Zl"))
    {
        return code_point == 0x002028;
    }
    if (std.mem.eql(u8, name, "Paragraph_Separator") or
        std.mem.eql(u8, name, "Zp") or
        std.mem.eql(u8, name, "General_Category=Paragraph_Separator") or
        std.mem.eql(u8, name, "General_Category=Zp") or
        std.mem.eql(u8, name, "gc=Paragraph_Separator") or
        std.mem.eql(u8, name, "gc=Zp"))
    {
        return code_point == 0x002029;
    }
    if (std.mem.eql(u8, name, "Space_Separator") or
        std.mem.eql(u8, name, "Zs") or
        std.mem.eql(u8, name, "General_Category=Space_Separator") or
        std.mem.eql(u8, name, "General_Category=Zs") or
        std.mem.eql(u8, name, "gc=Space_Separator") or
        std.mem.eql(u8, name, "gc=Zs"))
    {
        return code_point == 0x000020 or
            code_point == 0x0000a0 or
            code_point == 0x001680 or
            code_point == 0x00202f or
            code_point == 0x00205f or
            code_point == 0x003000 or
            (code_point >= 0x002000 and code_point <= 0x00200a);
    }
    if (std.mem.eql(u8, name, "Private_Use") or
        std.mem.eql(u8, name, "Co") or
        std.mem.eql(u8, name, "General_Category=Private_Use") or
        std.mem.eql(u8, name, "General_Category=Co") or
        std.mem.eql(u8, name, "gc=Private_Use") or
        std.mem.eql(u8, name, "gc=Co"))
    {
        return (code_point >= 0x00e000 and code_point <= 0x00f8ff) or
            (code_point >= 0x0f0000 and code_point <= 0x0ffffd) or
            (code_point >= 0x100000 and code_point <= 0x10fffd);
    }
    if (std.mem.eql(u8, name, "Surrogate") or
        std.mem.eql(u8, name, "Cs") or
        std.mem.eql(u8, name, "General_Category=Surrogate") or
        std.mem.eql(u8, name, "General_Category=Cs") or
        std.mem.eql(u8, name, "gc=Surrogate") or
        std.mem.eql(u8, name, "gc=Cs"))
    {
        return code_point >= 0x00d800 and code_point <= 0x00dfff;
    }
    if (std.mem.eql(u8, name, "Enclosing_Mark") or
        std.mem.eql(u8, name, "Me") or
        std.mem.eql(u8, name, "General_Category=Enclosing_Mark") or
        std.mem.eql(u8, name, "General_Category=Me") or
        std.mem.eql(u8, name, "gc=Enclosing_Mark") or
        std.mem.eql(u8, name, "gc=Me"))
    {
        return code_point == 0x001abe or
            (code_point >= 0x000488 and code_point <= 0x000489) or
            (code_point >= 0x0020dd and code_point <= 0x0020e0) or
            (code_point >= 0x0020e2 and code_point <= 0x0020e4) or
            (code_point >= 0x00a670 and code_point <= 0x00a672);
    }
    if (std.mem.eql(u8, name, "Currency_Symbol") or
        std.mem.eql(u8, name, "Sc") or
        std.mem.eql(u8, name, "General_Category=Currency_Symbol") or
        std.mem.eql(u8, name, "General_Category=Sc") or
        std.mem.eql(u8, name, "gc=Currency_Symbol") or
        std.mem.eql(u8, name, "gc=Sc"))
    {
        return code_point == 0x000024 or
            code_point == 0x00058f or
            code_point == 0x00060b or
            code_point == 0x0009fb or
            code_point == 0x000af1 or
            code_point == 0x000bf9 or
            code_point == 0x000e3f or
            code_point == 0x0017db or
            code_point == 0x00a838 or
            code_point == 0x00fdfc or
            code_point == 0x00fe69 or
            code_point == 0x00ff04 or
            code_point == 0x01e2ff or
            code_point == 0x01ecb0 or
            (code_point >= 0x0000a2 and code_point <= 0x0000a5) or
            (code_point >= 0x0007fe and code_point <= 0x0007ff) or
            (code_point >= 0x0009f2 and code_point <= 0x0009f3) or
            (code_point >= 0x0020a0 and code_point <= 0x0020c1) or
            (code_point >= 0x00ffe0 and code_point <= 0x00ffe1) or
            (code_point >= 0x00ffe5 and code_point <= 0x00ffe6) or
            (code_point >= 0x011fdd and code_point <= 0x011fe0);
    }
    if (std.mem.eql(u8, name, "Modifier_Symbol") or
        std.mem.eql(u8, name, "Sk") or
        std.mem.eql(u8, name, "General_Category=Modifier_Symbol") or
        std.mem.eql(u8, name, "General_Category=Sk") or
        std.mem.eql(u8, name, "gc=Modifier_Symbol") or
        std.mem.eql(u8, name, "gc=Sk"))
    {
        return code_point == 0x00005e or
            code_point == 0x000060 or
            code_point == 0x0000a8 or
            code_point == 0x0000af or
            code_point == 0x0000b4 or
            code_point == 0x0000b8 or
            code_point == 0x0002ed or
            code_point == 0x000375 or
            code_point == 0x000888 or
            code_point == 0x001fbd or
            code_point == 0x00ab5b or
            code_point == 0x00ff3e or
            code_point == 0x00ff40 or
            code_point == 0x00ffe3 or
            (code_point >= 0x0002c2 and code_point <= 0x0002c5) or
            (code_point >= 0x0002d2 and code_point <= 0x0002df) or
            (code_point >= 0x0002e5 and code_point <= 0x0002eb) or
            (code_point >= 0x0002ef and code_point <= 0x0002ff) or
            (code_point >= 0x000384 and code_point <= 0x000385) or
            (code_point >= 0x001fbf and code_point <= 0x001fc1) or
            (code_point >= 0x001fcd and code_point <= 0x001fcf) or
            (code_point >= 0x001fdd and code_point <= 0x001fdf) or
            (code_point >= 0x001fed and code_point <= 0x001fef) or
            (code_point >= 0x001ffd and code_point <= 0x001ffe) or
            (code_point >= 0x00309b and code_point <= 0x00309c) or
            (code_point >= 0x00a700 and code_point <= 0x00a716) or
            (code_point >= 0x00a720 and code_point <= 0x00a721) or
            (code_point >= 0x00a789 and code_point <= 0x00a78a) or
            (code_point >= 0x00ab6a and code_point <= 0x00ab6b) or
            (code_point >= 0x00fbb2 and code_point <= 0x00fbc2) or
            (code_point >= 0x01f3fb and code_point <= 0x01f3ff);
    }
    if (std.mem.eql(u8, name, "Dash_Punctuation") or
        std.mem.eql(u8, name, "Pd") or
        std.mem.eql(u8, name, "General_Category=Dash_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pd") or
        std.mem.eql(u8, name, "gc=Dash_Punctuation") or
        std.mem.eql(u8, name, "gc=Pd"))
    {
        return code_point == 0x00002d or
            code_point == 0x00058a or
            code_point == 0x0005be or
            code_point == 0x001400 or
            code_point == 0x001806 or
            code_point == 0x002e17 or
            code_point == 0x002e1a or
            code_point == 0x002e40 or
            code_point == 0x002e5d or
            code_point == 0x00301c or
            code_point == 0x003030 or
            code_point == 0x0030a0 or
            code_point == 0x00fe58 or
            code_point == 0x00fe63 or
            code_point == 0x00ff0d or
            code_point == 0x010d6e or
            code_point == 0x010ead or
            (code_point >= 0x002010 and code_point <= 0x002015) or
            (code_point >= 0x002e3a and code_point <= 0x002e3b) or
            (code_point >= 0x00fe31 and code_point <= 0x00fe32);
    }
    if (std.mem.eql(u8, name, "Initial_Punctuation") or
        std.mem.eql(u8, name, "Pi") or
        std.mem.eql(u8, name, "General_Category=Initial_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pi") or
        std.mem.eql(u8, name, "gc=Initial_Punctuation") or
        std.mem.eql(u8, name, "gc=Pi"))
    {
        return code_point == 0x0000ab or
            code_point == 0x002018 or
            code_point == 0x00201f or
            code_point == 0x002039 or
            code_point == 0x002e02 or
            code_point == 0x002e04 or
            code_point == 0x002e09 or
            code_point == 0x002e0c or
            code_point == 0x002e1c or
            code_point == 0x002e20 or
            (code_point >= 0x00201b and code_point <= 0x00201c);
    }
    if (std.mem.eql(u8, name, "Final_Punctuation") or
        std.mem.eql(u8, name, "Pf") or
        std.mem.eql(u8, name, "General_Category=Final_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pf") or
        std.mem.eql(u8, name, "gc=Final_Punctuation") or
        std.mem.eql(u8, name, "gc=Pf"))
    {
        return code_point == 0x0000bb or
            code_point == 0x002019 or
            code_point == 0x00201d or
            code_point == 0x00203a or
            code_point == 0x002e03 or
            code_point == 0x002e05 or
            code_point == 0x002e0a or
            code_point == 0x002e0d or
            code_point == 0x002e1d or
            code_point == 0x002e21;
    }
    if (std.mem.eql(u8, name, "Script=Adlam") or
        std.mem.eql(u8, name, "Script=Adlm") or
        std.mem.eql(u8, name, "sc=Adlam") or
        std.mem.eql(u8, name, "sc=Adlm"))
    {
        return (code_point >= 0x01e900 and code_point <= 0x01e94b) or
            (code_point >= 0x01e950 and code_point <= 0x01e959) or
            (code_point >= 0x01e95e and code_point <= 0x01e95f);
    }
    if (isAdlamScriptExtensionsName(name)) return isUnicodeAdlamScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Anatolian_Hieroglyphs") or
        std.mem.eql(u8, name, "Script=Hluw") or
        std.mem.eql(u8, name, "sc=Anatolian_Hieroglyphs") or
        std.mem.eql(u8, name, "sc=Hluw"))
    {
        return code_point >= 0x014400 and code_point <= 0x014646;
    }
    if (std.mem.eql(u8, name, "Script=Ahom") or
        std.mem.eql(u8, name, "sc=Ahom") or
        std.mem.eql(u8, name, "Script_Extensions=Ahom") or
        std.mem.eql(u8, name, "scx=Ahom"))
    {
        return (code_point >= 0x011700 and code_point <= 0x01171a) or
            (code_point >= 0x01171d and code_point <= 0x01172b) or
            (code_point >= 0x011730 and code_point <= 0x011746);
    }
    if (std.mem.eql(u8, name, "Script=Arabic") or
        std.mem.eql(u8, name, "Script=Arab") or
        std.mem.eql(u8, name, "sc=Arabic") or
        std.mem.eql(u8, name, "sc=Arab"))
    {
        return code_point == 0x01ee24 or
            code_point == 0x01ee27 or
            code_point == 0x01ee39 or
            code_point == 0x01ee3b or
            code_point == 0x01ee42 or
            code_point == 0x01ee47 or
            code_point == 0x01ee49 or
            code_point == 0x01ee4b or
            code_point == 0x01ee54 or
            code_point == 0x01ee57 or
            code_point == 0x01ee59 or
            code_point == 0x01ee5b or
            code_point == 0x01ee5d or
            code_point == 0x01ee5f or
            code_point == 0x01ee64 or
            code_point == 0x01ee7e or
            (code_point >= 0x000600 and code_point <= 0x000604) or
            (code_point >= 0x000606 and code_point <= 0x00060b) or
            (code_point >= 0x00060d and code_point <= 0x00061a) or
            (code_point >= 0x00061c and code_point <= 0x00061e) or
            (code_point >= 0x000620 and code_point <= 0x00063f) or
            (code_point >= 0x000641 and code_point <= 0x00064a) or
            (code_point >= 0x000656 and code_point <= 0x00066f) or
            (code_point >= 0x000671 and code_point <= 0x0006dc) or
            (code_point >= 0x0006de and code_point <= 0x0006ff) or
            (code_point >= 0x000750 and code_point <= 0x00077f) or
            (code_point >= 0x000870 and code_point <= 0x000891) or
            (code_point >= 0x000897 and code_point <= 0x0008e1) or
            (code_point >= 0x0008e3 and code_point <= 0x0008ff) or
            (code_point >= 0x00fb50 and code_point <= 0x00fd3d) or
            (code_point >= 0x00fd40 and code_point <= 0x00fdcf) or
            (code_point >= 0x00fdf0 and code_point <= 0x00fdff) or
            (code_point >= 0x00fe70 and code_point <= 0x00fe74) or
            (code_point >= 0x00fe76 and code_point <= 0x00fefc) or
            (code_point >= 0x010e60 and code_point <= 0x010e7e) or
            (code_point >= 0x010ec2 and code_point <= 0x010ec7) or
            (code_point >= 0x010ed0 and code_point <= 0x010ed8) or
            (code_point >= 0x010efa and code_point <= 0x010eff) or
            (code_point >= 0x01ee00 and code_point <= 0x01ee03) or
            (code_point >= 0x01ee05 and code_point <= 0x01ee1f) or
            (code_point >= 0x01ee21 and code_point <= 0x01ee22) or
            (code_point >= 0x01ee29 and code_point <= 0x01ee32) or
            (code_point >= 0x01ee34 and code_point <= 0x01ee37) or
            (code_point >= 0x01ee4d and code_point <= 0x01ee4f) or
            (code_point >= 0x01ee51 and code_point <= 0x01ee52) or
            (code_point >= 0x01ee61 and code_point <= 0x01ee62) or
            (code_point >= 0x01ee67 and code_point <= 0x01ee6a) or
            (code_point >= 0x01ee6c and code_point <= 0x01ee72) or
            (code_point >= 0x01ee74 and code_point <= 0x01ee77) or
            (code_point >= 0x01ee79 and code_point <= 0x01ee7c) or
            (code_point >= 0x01ee80 and code_point <= 0x01ee89) or
            (code_point >= 0x01ee8b and code_point <= 0x01ee9b) or
            (code_point >= 0x01eea1 and code_point <= 0x01eea3) or
            (code_point >= 0x01eea5 and code_point <= 0x01eea9) or
            (code_point >= 0x01eeab and code_point <= 0x01eebb) or
            (code_point >= 0x01eef0 and code_point <= 0x01eef1);
    }
    if (isArabicScriptExtensionsName(name)) return isUnicodeArabicScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Armenian") or
        std.mem.eql(u8, name, "Script=Armn") or
        std.mem.eql(u8, name, "sc=Armenian") or
        std.mem.eql(u8, name, "sc=Armn"))
    {
        return (code_point >= 0x000531 and code_point <= 0x000556) or
            (code_point >= 0x000559 and code_point <= 0x00058a) or
            (code_point >= 0x00058d and code_point <= 0x00058f) or
            (code_point >= 0x00fb13 and code_point <= 0x00fb17);
    }
    if (isArmenianScriptExtensionsName(name)) return isUnicodeArmenianScriptExtensionsCodePoint(code_point);
    if (isAvestanScriptExtensionsName(name)) return isUnicodeAvestanScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Avestan") or
        std.mem.eql(u8, name, "Script=Avst") or
        std.mem.eql(u8, name, "sc=Avestan") or
        std.mem.eql(u8, name, "sc=Avst"))
    {
        return (code_point >= 0x010b00 and code_point <= 0x010b35) or
            (code_point >= 0x010b39 and code_point <= 0x010b3f);
    }
    if (std.mem.eql(u8, name, "Script=Bassa_Vah") or
        std.mem.eql(u8, name, "Script=Bass") or
        std.mem.eql(u8, name, "sc=Bassa_Vah") or
        std.mem.eql(u8, name, "sc=Bass"))
    {
        return (code_point >= 0x016ad0 and code_point <= 0x016aed) or
            (code_point >= 0x016af0 and code_point <= 0x016af5);
    }
    if (std.mem.eql(u8, name, "Script=Beria_Erfe") or
        std.mem.eql(u8, name, "Script=Berf") or
        std.mem.eql(u8, name, "sc=Beria_Erfe") or
        std.mem.eql(u8, name, "sc=Berf"))
    {
        return (code_point >= 0x016ea0 and code_point <= 0x016eb8) or
            (code_point >= 0x016ebb and code_point <= 0x016ed3);
    }
    if (std.mem.eql(u8, name, "Script=Batak") or
        std.mem.eql(u8, name, "Script=Batk") or
        std.mem.eql(u8, name, "sc=Batak") or
        std.mem.eql(u8, name, "sc=Batk") or
        std.mem.eql(u8, name, "Script_Extensions=Batak") or
        std.mem.eql(u8, name, "Script_Extensions=Batk") or
        std.mem.eql(u8, name, "scx=Batak") or
        std.mem.eql(u8, name, "scx=Batk"))
    {
        return (code_point >= 0x001bc0 and code_point <= 0x001bf3) or
            (code_point >= 0x001bfc and code_point <= 0x001bff);
    }
    if (std.mem.eql(u8, name, "Script=Bengali") or
        std.mem.eql(u8, name, "Script=Beng") or
        std.mem.eql(u8, name, "sc=Bengali") or
        std.mem.eql(u8, name, "sc=Beng"))
    {
        return code_point == 0x0009b2 or
            code_point == 0x0009d7 or
            (code_point >= 0x000980 and code_point <= 0x000983) or
            (code_point >= 0x000985 and code_point <= 0x00098c) or
            (code_point >= 0x00098f and code_point <= 0x000990) or
            (code_point >= 0x000993 and code_point <= 0x0009a8) or
            (code_point >= 0x0009aa and code_point <= 0x0009b0) or
            (code_point >= 0x0009b6 and code_point <= 0x0009b9) or
            (code_point >= 0x0009bc and code_point <= 0x0009c4) or
            (code_point >= 0x0009c7 and code_point <= 0x0009c8) or
            (code_point >= 0x0009cb and code_point <= 0x0009ce) or
            (code_point >= 0x0009dc and code_point <= 0x0009dd) or
            (code_point >= 0x0009df and code_point <= 0x0009e3) or
            (code_point >= 0x0009e6 and code_point <= 0x0009fe);
    }
    if (isBengaliScriptExtensionsName(name)) return isUnicodeBengaliScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Bhaiksuki") or
        std.mem.eql(u8, name, "Script=Bhks") or
        std.mem.eql(u8, name, "sc=Bhaiksuki") or
        std.mem.eql(u8, name, "sc=Bhks"))
    {
        return (code_point >= 0x011c00 and code_point <= 0x011c08) or
            (code_point >= 0x011c0a and code_point <= 0x011c36) or
            (code_point >= 0x011c38 and code_point <= 0x011c45) or
            (code_point >= 0x011c50 and code_point <= 0x011c6c);
    }
    if (std.mem.eql(u8, name, "Script=Bopomofo") or
        std.mem.eql(u8, name, "Script=Bopo") or
        std.mem.eql(u8, name, "sc=Bopomofo") or
        std.mem.eql(u8, name, "sc=Bopo"))
    {
        return (code_point >= 0x0002ea and code_point <= 0x0002eb) or
            (code_point >= 0x003105 and code_point <= 0x00312f) or
            (code_point >= 0x0031a0 and code_point <= 0x0031bf);
    }
    if (isBopomofoScriptExtensionsName(name)) return isUnicodeBopomofoScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Balinese") or
        std.mem.eql(u8, name, "Script=Bali") or
        std.mem.eql(u8, name, "sc=Balinese") or
        std.mem.eql(u8, name, "sc=Bali"))
    {
        return (code_point >= 0x001b00 and code_point <= 0x001b4c) or
            (code_point >= 0x001b4e and code_point <= 0x001b7f);
    }
    if (std.mem.eql(u8, name, "Script=Bamum") or
        std.mem.eql(u8, name, "Script=Bamu") or
        std.mem.eql(u8, name, "sc=Bamum") or
        std.mem.eql(u8, name, "sc=Bamu"))
    {
        return (code_point >= 0x00a6a0 and code_point <= 0x00a6f7) or
            (code_point >= 0x016800 and code_point <= 0x016a38);
    }
    if (std.mem.eql(u8, name, "Script=Brahmi") or
        std.mem.eql(u8, name, "Script=Brah") or
        std.mem.eql(u8, name, "sc=Brahmi") or
        std.mem.eql(u8, name, "sc=Brah"))
    {
        return code_point == 0x01107f or
            (code_point >= 0x011000 and code_point <= 0x01104d) or
            (code_point >= 0x011052 and code_point <= 0x011075);
    }
    if (std.mem.eql(u8, name, "Script=Braille") or
        std.mem.eql(u8, name, "Script=Brai") or
        std.mem.eql(u8, name, "sc=Braille") or
        std.mem.eql(u8, name, "sc=Brai"))
    {
        return code_point >= 0x002800 and code_point <= 0x0028ff;
    }
    if (std.mem.eql(u8, name, "Script=Buginese") or
        std.mem.eql(u8, name, "Script=Bugi") or
        std.mem.eql(u8, name, "sc=Buginese") or
        std.mem.eql(u8, name, "sc=Bugi"))
    {
        return (code_point >= 0x001a00 and code_point <= 0x001a1b) or
            (code_point >= 0x001a1e and code_point <= 0x001a1f);
    }
    if (isBugineseScriptExtensionsName(name)) return isUnicodeBugineseScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Buhid") or
        std.mem.eql(u8, name, "Script=Buhd") or
        std.mem.eql(u8, name, "sc=Buhid") or
        std.mem.eql(u8, name, "sc=Buhd"))
    {
        return code_point >= 0x001740 and code_point <= 0x001753;
    }
    if (std.mem.eql(u8, name, "Script_Extensions=Buhid") or
        std.mem.eql(u8, name, "Script_Extensions=Buhd") or
        std.mem.eql(u8, name, "scx=Buhid") or
        std.mem.eql(u8, name, "scx=Buhd"))
    {
        return (code_point >= 0x001735 and code_point <= 0x001736) or
            (code_point >= 0x001740 and code_point <= 0x001753);
    }
    if (std.mem.eql(u8, name, "Script=Carian") or
        std.mem.eql(u8, name, "Script=Cari") or
        std.mem.eql(u8, name, "sc=Carian") or
        std.mem.eql(u8, name, "sc=Cari"))
    {
        return code_point >= 0x0102a0 and code_point <= 0x0102d0;
    }
    if (isCarianScriptExtensionsName(name)) return isUnicodeCarianScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Caucasian_Albanian") or
        std.mem.eql(u8, name, "Script=Aghb") or
        std.mem.eql(u8, name, "sc=Caucasian_Albanian") or
        std.mem.eql(u8, name, "sc=Aghb"))
    {
        return code_point == 0x01056f or
            (code_point >= 0x010530 and code_point <= 0x010563);
    }
    if (isCaucasianAlbanianScriptExtensionsName(name)) return isUnicodeCaucasianAlbanianScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Canadian_Aboriginal") or
        std.mem.eql(u8, name, "Script=Cans") or
        std.mem.eql(u8, name, "sc=Canadian_Aboriginal") or
        std.mem.eql(u8, name, "sc=Cans"))
    {
        return (code_point >= 0x001400 and code_point <= 0x00167f) or
            (code_point >= 0x0018b0 and code_point <= 0x0018f5) or
            (code_point >= 0x011ab0 and code_point <= 0x011abf);
    }
    if (std.mem.eql(u8, name, "Script=Unknown") or
        std.mem.eql(u8, name, "Script=Zzzz") or
        std.mem.eql(u8, name, "sc=Unknown") or
        std.mem.eql(u8, name, "sc=Zzzz") or
        std.mem.eql(u8, name, "Script_Extensions=Unknown") or
        std.mem.eql(u8, name, "Script_Extensions=Zzzz") or
        std.mem.eql(u8, name, "scx=Unknown") or
        std.mem.eql(u8, name, "scx=Zzzz"))
    {
        return isUnicodeUnknownScriptCodePoint(code_point);
    }
    if (std.mem.eql(u8, name, "Script=Common") or
        std.mem.eql(u8, name, "Script=Zyyy") or
        std.mem.eql(u8, name, "sc=Common") or
        std.mem.eql(u8, name, "sc=Zyyy"))
    {
        const singles = [_]u21{
            0x0000d7, 0x0000f7, 0x000374, 0x00037e, 0x000385, 0x000387, 0x000605, 0x00060c,
            0x00061b, 0x00061f, 0x000640, 0x0006dd, 0x0008e2, 0x000e3f, 0x0010fb, 0x001805,
            0x001cd3, 0x001ce1, 0x001cfa, 0x003006, 0x0030a0, 0x0031ef, 0x0032ff, 0x00a92e,
            0x00a9cf, 0x00ab5b, 0x00feff, 0x00ff70, 0x01d4a2, 0x01d4bb, 0x01d546, 0x01f7f0,
            0x01fac8, 0x0e0001,
        };
        const ranges = [_][2]u21{
            .{ 0x000000, 0x000040 },
            .{ 0x00005b, 0x000060 },
            .{ 0x00007b, 0x0000a9 },
            .{ 0x0000ab, 0x0000b9 },
            .{ 0x0000bb, 0x0000bf },
            .{ 0x0002b9, 0x0002df },
            .{ 0x0002e5, 0x0002e9 },
            .{ 0x0002ec, 0x0002ff },
            .{ 0x000964, 0x000965 },
            .{ 0x000fd5, 0x000fd8 },
            .{ 0x0016eb, 0x0016ed },
            .{ 0x001735, 0x001736 },
            .{ 0x001802, 0x001803 },
            .{ 0x001ce9, 0x001cec },
            .{ 0x001cee, 0x001cf3 },
            .{ 0x001cf5, 0x001cf7 },
            .{ 0x002000, 0x00200b },
            .{ 0x00200e, 0x002064 },
            .{ 0x002066, 0x002070 },
            .{ 0x002074, 0x00207e },
            .{ 0x002080, 0x00208e },
            .{ 0x0020a0, 0x0020c1 },
            .{ 0x002100, 0x002125 },
            .{ 0x002127, 0x002129 },
            .{ 0x00212c, 0x002131 },
            .{ 0x002133, 0x00214d },
            .{ 0x00214f, 0x00215f },
            .{ 0x002189, 0x00218b },
            .{ 0x002190, 0x002429 },
            .{ 0x002440, 0x00244a },
            .{ 0x002460, 0x0027ff },
            .{ 0x002900, 0x002b73 },
            .{ 0x002b76, 0x002bff },
            .{ 0x002e00, 0x002e5d },
            .{ 0x002ff0, 0x003004 },
            .{ 0x003008, 0x003020 },
            .{ 0x003030, 0x003037 },
            .{ 0x00303c, 0x00303f },
            .{ 0x00309b, 0x00309c },
            .{ 0x0030fb, 0x0030fc },
            .{ 0x003190, 0x00319f },
            .{ 0x0031c0, 0x0031e5 },
            .{ 0x003220, 0x00325f },
            .{ 0x00327f, 0x0032cf },
            .{ 0x003358, 0x0033ff },
            .{ 0x004dc0, 0x004dff },
            .{ 0x00a700, 0x00a721 },
            .{ 0x00a788, 0x00a78a },
            .{ 0x00a830, 0x00a839 },
            .{ 0x00ab6a, 0x00ab6b },
            .{ 0x00fd3e, 0x00fd3f },
            .{ 0x00fe10, 0x00fe19 },
            .{ 0x00fe30, 0x00fe52 },
            .{ 0x00fe54, 0x00fe66 },
            .{ 0x00fe68, 0x00fe6b },
            .{ 0x00ff01, 0x00ff20 },
            .{ 0x00ff3b, 0x00ff40 },
            .{ 0x00ff5b, 0x00ff65 },
            .{ 0x00ff9e, 0x00ff9f },
            .{ 0x00ffe0, 0x00ffe6 },
            .{ 0x00ffe8, 0x00ffee },
            .{ 0x00fff9, 0x00fffd },
            .{ 0x010100, 0x010102 },
            .{ 0x010107, 0x010133 },
            .{ 0x010137, 0x01013f },
            .{ 0x010190, 0x01019c },
            .{ 0x0101d0, 0x0101fc },
            .{ 0x0102e1, 0x0102fb },
            .{ 0x01bca0, 0x01bca3 },
            .{ 0x01cc00, 0x01ccfc },
            .{ 0x01cd00, 0x01ceb3 },
            .{ 0x01ceba, 0x01ced0 },
            .{ 0x01cee0, 0x01cef0 },
            .{ 0x01cf50, 0x01cfc3 },
            .{ 0x01d000, 0x01d0f5 },
            .{ 0x01d100, 0x01d126 },
            .{ 0x01d129, 0x01d166 },
            .{ 0x01d16a, 0x01d17a },
            .{ 0x01d183, 0x01d184 },
            .{ 0x01d18c, 0x01d1a9 },
            .{ 0x01d1ae, 0x01d1ea },
            .{ 0x01d2c0, 0x01d2d3 },
            .{ 0x01d2e0, 0x01d2f3 },
            .{ 0x01d300, 0x01d356 },
            .{ 0x01d360, 0x01d378 },
            .{ 0x01d400, 0x01d454 },
            .{ 0x01d456, 0x01d49c },
            .{ 0x01d49e, 0x01d49f },
            .{ 0x01d4a5, 0x01d4a6 },
            .{ 0x01d4a9, 0x01d4ac },
            .{ 0x01d4ae, 0x01d4b9 },
            .{ 0x01d4bd, 0x01d4c3 },
            .{ 0x01d4c5, 0x01d505 },
            .{ 0x01d507, 0x01d50a },
            .{ 0x01d50d, 0x01d514 },
            .{ 0x01d516, 0x01d51c },
            .{ 0x01d51e, 0x01d539 },
            .{ 0x01d53b, 0x01d53e },
            .{ 0x01d540, 0x01d544 },
            .{ 0x01d54a, 0x01d550 },
            .{ 0x01d552, 0x01d6a5 },
            .{ 0x01d6a8, 0x01d7cb },
            .{ 0x01d7ce, 0x01d7ff },
            .{ 0x01ec71, 0x01ecb4 },
            .{ 0x01ed01, 0x01ed3d },
            .{ 0x01f000, 0x01f02b },
            .{ 0x01f030, 0x01f093 },
            .{ 0x01f0a0, 0x01f0ae },
            .{ 0x01f0b1, 0x01f0bf },
            .{ 0x01f0c1, 0x01f0cf },
            .{ 0x01f0d1, 0x01f0f5 },
            .{ 0x01f100, 0x01f1ad },
            .{ 0x01f1e6, 0x01f1ff },
            .{ 0x01f201, 0x01f202 },
            .{ 0x01f210, 0x01f23b },
            .{ 0x01f240, 0x01f248 },
            .{ 0x01f250, 0x01f251 },
            .{ 0x01f260, 0x01f265 },
            .{ 0x01f300, 0x01f6d8 },
            .{ 0x01f6dc, 0x01f6ec },
            .{ 0x01f6f0, 0x01f6fc },
            .{ 0x01f700, 0x01f7d9 },
            .{ 0x01f7e0, 0x01f7eb },
            .{ 0x01f800, 0x01f80b },
            .{ 0x01f810, 0x01f847 },
            .{ 0x01f850, 0x01f859 },
            .{ 0x01f860, 0x01f887 },
            .{ 0x01f890, 0x01f8ad },
            .{ 0x01f8b0, 0x01f8bb },
            .{ 0x01f8c0, 0x01f8c1 },
            .{ 0x01f8d0, 0x01f8d8 },
            .{ 0x01f900, 0x01fa57 },
            .{ 0x01fa60, 0x01fa6d },
            .{ 0x01fa70, 0x01fa7c },
            .{ 0x01fa80, 0x01fa8a },
            .{ 0x01fa8e, 0x01fac6 },
            .{ 0x01facd, 0x01fadc },
            .{ 0x01fadf, 0x01faea },
            .{ 0x01faef, 0x01faf8 },
            .{ 0x01fb00, 0x01fb92 },
            .{ 0x01fb94, 0x01fbfa },
            .{ 0x0e0020, 0x0e007f },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (isCommonScriptExtensionsName(name)) return isUnicodeCommonScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Chakma") or
        std.mem.eql(u8, name, "Script=Cakm") or
        std.mem.eql(u8, name, "sc=Chakma") or
        std.mem.eql(u8, name, "sc=Cakm"))
    {
        return (code_point >= 0x011100 and code_point <= 0x011134) or
            (code_point >= 0x011136 and code_point <= 0x011147);
    }
    if (isChakmaScriptExtensionsName(name)) return isUnicodeChakmaScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Cham") or std.mem.eql(u8, name, "sc=Cham")) {
        return (code_point >= 0x00aa00 and code_point <= 0x00aa36) or
            (code_point >= 0x00aa40 and code_point <= 0x00aa4d) or
            (code_point >= 0x00aa50 and code_point <= 0x00aa59) or
            (code_point >= 0x00aa5c and code_point <= 0x00aa5f);
    }
    if (std.mem.eql(u8, name, "Script=Cherokee") or
        std.mem.eql(u8, name, "Script=Cher") or
        std.mem.eql(u8, name, "sc=Cherokee") or
        std.mem.eql(u8, name, "sc=Cher"))
    {
        return (code_point >= 0x0013a0 and code_point <= 0x0013f5) or
            (code_point >= 0x0013f8 and code_point <= 0x0013fd) or
            (code_point >= 0x00ab70 and code_point <= 0x00abbf);
    }
    if (isCherokeeScriptExtensionsName(name)) return isUnicodeCherokeeScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Chorasmian") or
        std.mem.eql(u8, name, "Script=Chrs") or
        std.mem.eql(u8, name, "sc=Chorasmian") or
        std.mem.eql(u8, name, "sc=Chrs"))
    {
        return code_point >= 0x010fb0 and code_point <= 0x010fcb;
    }
    if (std.mem.eql(u8, name, "Script=Coptic") or
        std.mem.eql(u8, name, "Script=Copt") or
        std.mem.eql(u8, name, "Script=Qaac") or
        std.mem.eql(u8, name, "sc=Coptic") or
        std.mem.eql(u8, name, "sc=Copt") or
        std.mem.eql(u8, name, "sc=Qaac"))
    {
        return (code_point >= 0x0003e2 and code_point <= 0x0003ef) or
            (code_point >= 0x002c80 and code_point <= 0x002cf3) or
            (code_point >= 0x002cf9 and code_point <= 0x002cff);
    }
    if (isCopticScriptExtensionsName(name)) return isUnicodeCopticScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Cyrillic") or
        std.mem.eql(u8, name, "Script=Cyrl") or
        std.mem.eql(u8, name, "sc=Cyrillic") or
        std.mem.eql(u8, name, "sc=Cyrl"))
    {
        return code_point == 0x001d2b or
            code_point == 0x001d78 or
            code_point == 0x01e08f or
            (code_point >= 0x000400 and code_point <= 0x000484) or
            (code_point >= 0x000487 and code_point <= 0x00052f) or
            (code_point >= 0x001c80 and code_point <= 0x001c8a) or
            (code_point >= 0x002de0 and code_point <= 0x002dff) or
            (code_point >= 0x00a640 and code_point <= 0x00a69f) or
            (code_point >= 0x00fe2e and code_point <= 0x00fe2f) or
            (code_point >= 0x01e030 and code_point <= 0x01e06d);
    }
    if (isCyrillicScriptExtensionsName(name)) return isUnicodeCyrillicScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Cuneiform") or
        std.mem.eql(u8, name, "Script=Xsux") or
        std.mem.eql(u8, name, "sc=Cuneiform") or
        std.mem.eql(u8, name, "sc=Xsux"))
    {
        return (code_point >= 0x012000 and code_point <= 0x012399) or
            (code_point >= 0x012400 and code_point <= 0x01246e) or
            (code_point >= 0x012470 and code_point <= 0x012474) or
            (code_point >= 0x012480 and code_point <= 0x012543);
    }
    if (std.mem.eql(u8, name, "Script=Cypro_Minoan") or
        std.mem.eql(u8, name, "Script=Cpmn") or
        std.mem.eql(u8, name, "sc=Cypro_Minoan") or
        std.mem.eql(u8, name, "sc=Cpmn"))
    {
        return code_point >= 0x012f90 and code_point <= 0x012ff2;
    }
    if (std.mem.eql(u8, name, "Script_Extensions=Cypro_Minoan") or
        std.mem.eql(u8, name, "Script_Extensions=Cpmn") or
        std.mem.eql(u8, name, "scx=Cypro_Minoan") or
        std.mem.eql(u8, name, "scx=Cpmn"))
    {
        return (code_point >= 0x010100 and code_point <= 0x010101) or
            (code_point >= 0x012f90 and code_point <= 0x012ff2);
    }
    if (std.mem.eql(u8, name, "Script=Cypriot") or
        std.mem.eql(u8, name, "Script=Cprt") or
        std.mem.eql(u8, name, "sc=Cypriot") or
        std.mem.eql(u8, name, "sc=Cprt"))
    {
        return code_point == 0x010808 or
            code_point == 0x01083c or
            code_point == 0x01083f or
            (code_point >= 0x010800 and code_point <= 0x010805) or
            (code_point >= 0x01080a and code_point <= 0x010835) or
            (code_point >= 0x010837 and code_point <= 0x010838);
    }
    if (isCypriotScriptExtensionsName(name)) return isUnicodeCypriotScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Devanagari") or
        std.mem.eql(u8, name, "Script=Deva") or
        std.mem.eql(u8, name, "sc=Devanagari") or
        std.mem.eql(u8, name, "sc=Deva"))
    {
        return (code_point >= 0x000900 and code_point <= 0x000950) or
            (code_point >= 0x000955 and code_point <= 0x000963) or
            (code_point >= 0x000966 and code_point <= 0x00097f) or
            (code_point >= 0x00a8e0 and code_point <= 0x00a8ff) or
            (code_point >= 0x011b00 and code_point <= 0x011b09);
    }
    if (isDevanagariScriptExtensionsName(name)) return isUnicodeDevanagariScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Deseret") or
        std.mem.eql(u8, name, "Script=Dsrt") or
        std.mem.eql(u8, name, "sc=Deseret") or
        std.mem.eql(u8, name, "sc=Dsrt"))
    {
        return code_point >= 0x010400 and code_point <= 0x01044f;
    }
    if (std.mem.eql(u8, name, "Script=Dives_Akuru") or
        std.mem.eql(u8, name, "Script=Diak") or
        std.mem.eql(u8, name, "sc=Dives_Akuru") or
        std.mem.eql(u8, name, "sc=Diak") or
        std.mem.eql(u8, name, "Script_Extensions=Dives_Akuru") or
        std.mem.eql(u8, name, "Script_Extensions=Diak") or
        std.mem.eql(u8, name, "scx=Dives_Akuru") or
        std.mem.eql(u8, name, "scx=Diak"))
    {
        return code_point == 0x011909 or
            (code_point >= 0x011900 and code_point <= 0x011906) or
            (code_point >= 0x01190c and code_point <= 0x011913) or
            (code_point >= 0x011915 and code_point <= 0x011916) or
            (code_point >= 0x011918 and code_point <= 0x011935) or
            (code_point >= 0x011937 and code_point <= 0x011938) or
            (code_point >= 0x01193b and code_point <= 0x011946) or
            (code_point >= 0x011950 and code_point <= 0x011959);
    }
    if (std.mem.eql(u8, name, "Script=Duployan") or
        std.mem.eql(u8, name, "Script=Dupl") or
        std.mem.eql(u8, name, "sc=Duployan") or
        std.mem.eql(u8, name, "sc=Dupl"))
    {
        return (code_point >= 0x01bc00 and code_point <= 0x01bc6a) or
            (code_point >= 0x01bc70 and code_point <= 0x01bc7c) or
            (code_point >= 0x01bc80 and code_point <= 0x01bc88) or
            (code_point >= 0x01bc90 and code_point <= 0x01bc99) or
            (code_point >= 0x01bc9c and code_point <= 0x01bc9f);
    }
    if (isDuployanScriptExtensionsName(name)) return isUnicodeDuployanScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Dogra") or
        std.mem.eql(u8, name, "Script=Dogr") or
        std.mem.eql(u8, name, "sc=Dogra") or
        std.mem.eql(u8, name, "sc=Dogr"))
    {
        return code_point >= 0x011800 and code_point <= 0x01183b;
    }
    if (isDograScriptExtensionsName(name)) return isUnicodeDograScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Elbasan") or
        std.mem.eql(u8, name, "Script=Elba") or
        std.mem.eql(u8, name, "sc=Elbasan") or
        std.mem.eql(u8, name, "sc=Elba"))
    {
        return code_point >= 0x010500 and code_point <= 0x010527;
    }
    if (isElbasanScriptExtensionsName(name)) return isUnicodeElbasanScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Elymaic") or
        std.mem.eql(u8, name, "Script=Elym") or
        std.mem.eql(u8, name, "sc=Elymaic") or
        std.mem.eql(u8, name, "sc=Elym"))
    {
        return code_point >= 0x010fe0 and code_point <= 0x010ff6;
    }
    if (std.mem.eql(u8, name, "Script=Egyptian_Hieroglyphs") or
        std.mem.eql(u8, name, "Script=Egyp") or
        std.mem.eql(u8, name, "sc=Egyptian_Hieroglyphs") or
        std.mem.eql(u8, name, "sc=Egyp"))
    {
        return (code_point >= 0x013000 and code_point <= 0x013455) or
            (code_point >= 0x013460 and code_point <= 0x0143fa);
    }
    if (std.mem.eql(u8, name, "Script=Ethiopic") or
        std.mem.eql(u8, name, "Script=Ethi") or
        std.mem.eql(u8, name, "sc=Ethiopic") or
        std.mem.eql(u8, name, "sc=Ethi"))
    {
        return code_point == 0x001258 or
            code_point == 0x0012c0 or
            (code_point >= 0x001200 and code_point <= 0x001248) or
            (code_point >= 0x00124a and code_point <= 0x00124d) or
            (code_point >= 0x001250 and code_point <= 0x001256) or
            (code_point >= 0x00125a and code_point <= 0x00125d) or
            (code_point >= 0x001260 and code_point <= 0x001288) or
            (code_point >= 0x00128a and code_point <= 0x00128d) or
            (code_point >= 0x001290 and code_point <= 0x0012b0) or
            (code_point >= 0x0012b2 and code_point <= 0x0012b5) or
            (code_point >= 0x0012b8 and code_point <= 0x0012be) or
            (code_point >= 0x0012c2 and code_point <= 0x0012c5) or
            (code_point >= 0x0012c8 and code_point <= 0x0012d6) or
            (code_point >= 0x0012d8 and code_point <= 0x001310) or
            (code_point >= 0x001312 and code_point <= 0x001315) or
            (code_point >= 0x001318 and code_point <= 0x00135a) or
            (code_point >= 0x00135d and code_point <= 0x00137c) or
            (code_point >= 0x001380 and code_point <= 0x001399) or
            (code_point >= 0x002d80 and code_point <= 0x002d96) or
            (code_point >= 0x002da0 and code_point <= 0x002da6) or
            (code_point >= 0x002da8 and code_point <= 0x002dae) or
            (code_point >= 0x002db0 and code_point <= 0x002db6) or
            (code_point >= 0x002db8 and code_point <= 0x002dbe) or
            (code_point >= 0x002dc0 and code_point <= 0x002dc6) or
            (code_point >= 0x002dc8 and code_point <= 0x002dce) or
            (code_point >= 0x002dd0 and code_point <= 0x002dd6) or
            (code_point >= 0x002dd8 and code_point <= 0x002dde) or
            (code_point >= 0x00ab01 and code_point <= 0x00ab06) or
            (code_point >= 0x00ab09 and code_point <= 0x00ab0e) or
            (code_point >= 0x00ab11 and code_point <= 0x00ab16) or
            (code_point >= 0x00ab20 and code_point <= 0x00ab26) or
            (code_point >= 0x00ab28 and code_point <= 0x00ab2e) or
            (code_point >= 0x01e7e0 and code_point <= 0x01e7e6) or
            (code_point >= 0x01e7e8 and code_point <= 0x01e7eb) or
            (code_point >= 0x01e7ed and code_point <= 0x01e7ee) or
            (code_point >= 0x01e7f0 and code_point <= 0x01e7fe);
    }
    if (isEthiopicScriptExtensionsName(name)) return isUnicodeEthiopicScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Garay") or
        std.mem.eql(u8, name, "Script=Gara") or
        std.mem.eql(u8, name, "sc=Garay") or
        std.mem.eql(u8, name, "sc=Gara"))
    {
        return (code_point >= 0x010d40 and code_point <= 0x010d65) or
            (code_point >= 0x010d69 and code_point <= 0x010d85) or
            (code_point >= 0x010d8e and code_point <= 0x010d8f);
    }
    if (isGarayScriptExtensionsName(name)) return isUnicodeGarayScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Georgian") or
        std.mem.eql(u8, name, "Script=Geor") or
        std.mem.eql(u8, name, "sc=Georgian") or
        std.mem.eql(u8, name, "sc=Geor"))
    {
        return code_point == 0x0010c7 or
            code_point == 0x0010cd or
            code_point == 0x002d27 or
            code_point == 0x002d2d or
            (code_point >= 0x0010a0 and code_point <= 0x0010c5) or
            (code_point >= 0x0010d0 and code_point <= 0x0010fa) or
            (code_point >= 0x0010fc and code_point <= 0x0010ff) or
            (code_point >= 0x001c90 and code_point <= 0x001cba) or
            (code_point >= 0x001cbd and code_point <= 0x001cbf) or
            (code_point >= 0x002d00 and code_point <= 0x002d25);
    }
    if (isGeorgianScriptExtensionsName(name)) return isUnicodeGeorgianScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Glagolitic") or
        std.mem.eql(u8, name, "Script=Glag") or
        std.mem.eql(u8, name, "sc=Glagolitic") or
        std.mem.eql(u8, name, "sc=Glag"))
    {
        return (code_point >= 0x002c00 and code_point <= 0x002c5f) or
            (code_point >= 0x01e000 and code_point <= 0x01e006) or
            (code_point >= 0x01e008 and code_point <= 0x01e018) or
            (code_point >= 0x01e01b and code_point <= 0x01e021) or
            (code_point >= 0x01e023 and code_point <= 0x01e024) or
            (code_point >= 0x01e026 and code_point <= 0x01e02a);
    }
    if (isGlagoliticScriptExtensionsName(name)) return isUnicodeGlagoliticScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Gothic") or
        std.mem.eql(u8, name, "Script=Goth") or
        std.mem.eql(u8, name, "sc=Gothic") or
        std.mem.eql(u8, name, "sc=Goth"))
    {
        return code_point >= 0x010330 and code_point <= 0x01034a;
    }
    if (isGothicScriptExtensionsName(name)) return isUnicodeGothicScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Greek") or
        std.mem.eql(u8, name, "Script=Grek") or
        std.mem.eql(u8, name, "sc=Greek") or
        std.mem.eql(u8, name, "sc=Grek"))
    {
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
    if (isGreekScriptExtensionsName(name)) return isUnicodeGreekScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Grantha") or
        std.mem.eql(u8, name, "Script=Gran") or
        std.mem.eql(u8, name, "sc=Grantha") or
        std.mem.eql(u8, name, "sc=Gran"))
    {
        return code_point == 0x011350 or
            code_point == 0x011357 or
            (code_point >= 0x011300 and code_point <= 0x011303) or
            (code_point >= 0x011305 and code_point <= 0x01130c) or
            (code_point >= 0x01130f and code_point <= 0x011310) or
            (code_point >= 0x011313 and code_point <= 0x011328) or
            (code_point >= 0x01132a and code_point <= 0x011330) or
            (code_point >= 0x011332 and code_point <= 0x011333) or
            (code_point >= 0x011335 and code_point <= 0x011339) or
            (code_point >= 0x01133c and code_point <= 0x011344) or
            (code_point >= 0x011347 and code_point <= 0x011348) or
            (code_point >= 0x01134b and code_point <= 0x01134d) or
            (code_point >= 0x01135d and code_point <= 0x011363) or
            (code_point >= 0x011366 and code_point <= 0x01136c) or
            (code_point >= 0x011370 and code_point <= 0x011374);
    }
    if (isGranthaScriptExtensionsName(name)) return isUnicodeGranthaScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Gunjala_Gondi") or
        std.mem.eql(u8, name, "Script=Gong") or
        std.mem.eql(u8, name, "sc=Gunjala_Gondi") or
        std.mem.eql(u8, name, "sc=Gong"))
    {
        return (code_point >= 0x011d60 and code_point <= 0x011d65) or
            (code_point >= 0x011d67 and code_point <= 0x011d68) or
            (code_point >= 0x011d6a and code_point <= 0x011d8e) or
            (code_point >= 0x011d90 and code_point <= 0x011d91) or
            (code_point >= 0x011d93 and code_point <= 0x011d98) or
            (code_point >= 0x011da0 and code_point <= 0x011da9);
    }
    if (isGunjalaGondiScriptExtensionsName(name)) return isUnicodeGunjalaGondiScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Gurung_Khema") or
        std.mem.eql(u8, name, "Script=Gukh") or
        std.mem.eql(u8, name, "sc=Gurung_Khema") or
        std.mem.eql(u8, name, "sc=Gukh"))
    {
        return code_point >= 0x016100 and code_point <= 0x016139;
    }
    if (std.mem.eql(u8, name, "Script_Extensions=Gurung_Khema") or
        std.mem.eql(u8, name, "Script_Extensions=Gukh") or
        std.mem.eql(u8, name, "scx=Gurung_Khema") or
        std.mem.eql(u8, name, "scx=Gukh"))
    {
        return code_point == 0x000965 or
            (code_point >= 0x016100 and code_point <= 0x016139);
    }
    if (std.mem.eql(u8, name, "Script=Gurmukhi") or
        std.mem.eql(u8, name, "Script=Guru") or
        std.mem.eql(u8, name, "sc=Gurmukhi") or
        std.mem.eql(u8, name, "sc=Guru"))
    {
        return code_point == 0x000a3c or
            code_point == 0x000a51 or
            code_point == 0x000a5e or
            (code_point >= 0x000a01 and code_point <= 0x000a03) or
            (code_point >= 0x000a05 and code_point <= 0x000a0a) or
            (code_point >= 0x000a0f and code_point <= 0x000a10) or
            (code_point >= 0x000a13 and code_point <= 0x000a28) or
            (code_point >= 0x000a2a and code_point <= 0x000a30) or
            (code_point >= 0x000a32 and code_point <= 0x000a33) or
            (code_point >= 0x000a35 and code_point <= 0x000a36) or
            (code_point >= 0x000a38 and code_point <= 0x000a39) or
            (code_point >= 0x000a3e and code_point <= 0x000a42) or
            (code_point >= 0x000a47 and code_point <= 0x000a48) or
            (code_point >= 0x000a4b and code_point <= 0x000a4d) or
            (code_point >= 0x000a59 and code_point <= 0x000a5c) or
            (code_point >= 0x000a66 and code_point <= 0x000a76);
    }
    if (isGurmukhiScriptExtensionsName(name)) return isUnicodeGurmukhiScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Gujarati") or
        std.mem.eql(u8, name, "Script=Gujr") or
        std.mem.eql(u8, name, "sc=Gujarati") or
        std.mem.eql(u8, name, "sc=Gujr"))
    {
        return code_point == 0x000ad0 or
            (code_point >= 0x000a81 and code_point <= 0x000a83) or
            (code_point >= 0x000a85 and code_point <= 0x000a8d) or
            (code_point >= 0x000a8f and code_point <= 0x000a91) or
            (code_point >= 0x000a93 and code_point <= 0x000aa8) or
            (code_point >= 0x000aaa and code_point <= 0x000ab0) or
            (code_point >= 0x000ab2 and code_point <= 0x000ab3) or
            (code_point >= 0x000ab5 and code_point <= 0x000ab9) or
            (code_point >= 0x000abc and code_point <= 0x000ac5) or
            (code_point >= 0x000ac7 and code_point <= 0x000ac9) or
            (code_point >= 0x000acb and code_point <= 0x000acd) or
            (code_point >= 0x000ae0 and code_point <= 0x000ae3) or
            (code_point >= 0x000ae6 and code_point <= 0x000af1) or
            (code_point >= 0x000af9 and code_point <= 0x000aff);
    }
    if (isGujaratiScriptExtensionsName(name)) return isUnicodeGujaratiScriptExtensionsCodePoint(code_point);
    if (isHanScriptName(name)) return isUnicodeHanScriptCodePoint(code_point);
    if (isHanScriptExtensionsName(name)) return isUnicodeHanScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Hangul") or
        std.mem.eql(u8, name, "Script=Hang") or
        std.mem.eql(u8, name, "sc=Hangul") or
        std.mem.eql(u8, name, "sc=Hang"))
    {
        return (code_point >= 0x001100 and code_point <= 0x0011ff) or
            (code_point >= 0x00302e and code_point <= 0x00302f) or
            (code_point >= 0x003131 and code_point <= 0x00318e) or
            (code_point >= 0x003200 and code_point <= 0x00321e) or
            (code_point >= 0x003260 and code_point <= 0x00327e) or
            (code_point >= 0x00a960 and code_point <= 0x00a97c) or
            (code_point >= 0x00ac00 and code_point <= 0x00d7a3) or
            (code_point >= 0x00d7b0 and code_point <= 0x00d7c6) or
            (code_point >= 0x00d7cb and code_point <= 0x00d7fb) or
            (code_point >= 0x00ffa0 and code_point <= 0x00ffbe) or
            (code_point >= 0x00ffc2 and code_point <= 0x00ffc7) or
            (code_point >= 0x00ffca and code_point <= 0x00ffcf) or
            (code_point >= 0x00ffd2 and code_point <= 0x00ffd7) or
            (code_point >= 0x00ffda and code_point <= 0x00ffdc);
    }
    if (isHangulScriptExtensionsName(name)) return isUnicodeHangulScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Hanunoo") or
        std.mem.eql(u8, name, "Script=Hano") or
        std.mem.eql(u8, name, "sc=Hanunoo") or
        std.mem.eql(u8, name, "sc=Hano"))
    {
        return code_point >= 0x001720 and code_point <= 0x001734;
    }
    if (std.mem.eql(u8, name, "Script_Extensions=Hanunoo") or
        std.mem.eql(u8, name, "Script_Extensions=Hano") or
        std.mem.eql(u8, name, "scx=Hanunoo") or
        std.mem.eql(u8, name, "scx=Hano"))
    {
        return code_point >= 0x001720 and code_point <= 0x001736;
    }
    if (std.mem.eql(u8, name, "Script=Hatran") or
        std.mem.eql(u8, name, "Script=Hatr") or
        std.mem.eql(u8, name, "sc=Hatran") or
        std.mem.eql(u8, name, "sc=Hatr"))
    {
        return (code_point >= 0x0108e0 and code_point <= 0x0108f2) or
            (code_point >= 0x0108f4 and code_point <= 0x0108f5) or
            (code_point >= 0x0108fb and code_point <= 0x0108ff);
    }
    if (std.mem.eql(u8, name, "Script=Hanifi_Rohingya") or
        std.mem.eql(u8, name, "Script=Rohg") or
        std.mem.eql(u8, name, "sc=Hanifi_Rohingya") or
        std.mem.eql(u8, name, "sc=Rohg"))
    {
        return (code_point >= 0x010d00 and code_point <= 0x010d27) or
            (code_point >= 0x010d30 and code_point <= 0x010d39);
    }
    if (isHanifiRohingyaScriptExtensionsName(name)) return isUnicodeHanifiRohingyaScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Hebrew") or
        std.mem.eql(u8, name, "Script=Hebr") or
        std.mem.eql(u8, name, "sc=Hebrew") or
        std.mem.eql(u8, name, "sc=Hebr"))
    {
        return code_point == 0x00fb3e or
            (code_point >= 0x000591 and code_point <= 0x0005c7) or
            (code_point >= 0x0005d0 and code_point <= 0x0005ea) or
            (code_point >= 0x0005ef and code_point <= 0x0005f4) or
            (code_point >= 0x00fb1d and code_point <= 0x00fb36) or
            (code_point >= 0x00fb38 and code_point <= 0x00fb3c) or
            (code_point >= 0x00fb40 and code_point <= 0x00fb41) or
            (code_point >= 0x00fb43 and code_point <= 0x00fb44) or
            (code_point >= 0x00fb46 and code_point <= 0x00fb4f);
    }
    if (isHebrewScriptExtensionsName(name)) return isUnicodeHebrewScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Hiragana") or
        std.mem.eql(u8, name, "Script=Hira") or
        std.mem.eql(u8, name, "sc=Hiragana") or
        std.mem.eql(u8, name, "sc=Hira"))
    {
        return code_point == 0x01b132 or
            code_point == 0x01f200 or
            (code_point >= 0x003041 and code_point <= 0x003096) or
            (code_point >= 0x00309d and code_point <= 0x00309f) or
            (code_point >= 0x01b001 and code_point <= 0x01b11f) or
            (code_point >= 0x01b150 and code_point <= 0x01b152);
    }
    if (isHiraganaScriptExtensionsName(name)) return isUnicodeHiraganaScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Inherited") or
        std.mem.eql(u8, name, "Script=Zinh") or
        std.mem.eql(u8, name, "Script=Qaai") or
        std.mem.eql(u8, name, "sc=Inherited") or
        std.mem.eql(u8, name, "sc=Zinh") or
        std.mem.eql(u8, name, "sc=Qaai"))
    {
        return code_point == 0x000670 or
            code_point == 0x001ced or
            code_point == 0x001cf4 or
            code_point == 0x0101fd or
            code_point == 0x0102e0 or
            code_point == 0x01133b or
            (code_point >= 0x000300 and code_point <= 0x00036f) or
            (code_point >= 0x000485 and code_point <= 0x000486) or
            (code_point >= 0x00064b and code_point <= 0x000655) or
            (code_point >= 0x000951 and code_point <= 0x000954) or
            (code_point >= 0x001ab0 and code_point <= 0x001add) or
            (code_point >= 0x001ae0 and code_point <= 0x001aeb) or
            (code_point >= 0x001cd0 and code_point <= 0x001cd2) or
            (code_point >= 0x001cd4 and code_point <= 0x001ce0) or
            (code_point >= 0x001ce2 and code_point <= 0x001ce8) or
            (code_point >= 0x001cf8 and code_point <= 0x001cf9) or
            (code_point >= 0x001dc0 and code_point <= 0x001dff) or
            (code_point >= 0x00200c and code_point <= 0x00200d) or
            (code_point >= 0x0020d0 and code_point <= 0x0020f0) or
            (code_point >= 0x00302a and code_point <= 0x00302d) or
            (code_point >= 0x003099 and code_point <= 0x00309a) or
            (code_point >= 0x00fe00 and code_point <= 0x00fe0f) or
            (code_point >= 0x00fe20 and code_point <= 0x00fe2d) or
            (code_point >= 0x01cf00 and code_point <= 0x01cf2d) or
            (code_point >= 0x01cf30 and code_point <= 0x01cf46) or
            (code_point >= 0x01d167 and code_point <= 0x01d169) or
            (code_point >= 0x01d17b and code_point <= 0x01d182) or
            (code_point >= 0x01d185 and code_point <= 0x01d18b) or
            (code_point >= 0x01d1aa and code_point <= 0x01d1ad) or
            (code_point >= 0x0e0100 and code_point <= 0x0e01ef);
    }
    if (isInheritedScriptExtensionsName(name)) return isUnicodeInheritedScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Inscriptional_Pahlavi") or
        std.mem.eql(u8, name, "Script=Phli") or
        std.mem.eql(u8, name, "sc=Inscriptional_Pahlavi") or
        std.mem.eql(u8, name, "sc=Phli"))
    {
        return (code_point >= 0x010b60 and code_point <= 0x010b72) or
            (code_point >= 0x010b78 and code_point <= 0x010b7f);
    }
    if (std.mem.eql(u8, name, "Script=Inscriptional_Parthian") or
        std.mem.eql(u8, name, "Script=Prti") or
        std.mem.eql(u8, name, "sc=Inscriptional_Parthian") or
        std.mem.eql(u8, name, "sc=Prti"))
    {
        return (code_point >= 0x010b40 and code_point <= 0x010b55) or
            (code_point >= 0x010b58 and code_point <= 0x010b5f);
    }
    if (std.mem.eql(u8, name, "Script=Imperial_Aramaic") or
        std.mem.eql(u8, name, "Script=Armi") or
        std.mem.eql(u8, name, "sc=Imperial_Aramaic") or
        std.mem.eql(u8, name, "sc=Armi") or
        std.mem.eql(u8, name, "Script_Extensions=Imperial_Aramaic") or
        std.mem.eql(u8, name, "Script_Extensions=Armi") or
        std.mem.eql(u8, name, "scx=Imperial_Aramaic") or
        std.mem.eql(u8, name, "scx=Armi"))
    {
        return (code_point >= 0x010840 and code_point <= 0x010855) or
            (code_point >= 0x010857 and code_point <= 0x01085f);
    }
    if (std.mem.eql(u8, name, "Script=Javanese") or
        std.mem.eql(u8, name, "Script=Java") or
        std.mem.eql(u8, name, "sc=Javanese") or
        std.mem.eql(u8, name, "sc=Java"))
    {
        return (code_point >= 0x00a980 and code_point <= 0x00a9cd) or
            (code_point >= 0x00a9d0 and code_point <= 0x00a9d9) or
            (code_point >= 0x00a9de and code_point <= 0x00a9df);
    }
    if (isJavaneseScriptExtensionsName(name)) return isUnicodeJavaneseScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Kaithi") or
        std.mem.eql(u8, name, "Script=Kthi") or
        std.mem.eql(u8, name, "sc=Kaithi") or
        std.mem.eql(u8, name, "sc=Kthi"))
    {
        return code_point == 0x0110cd or
            (code_point >= 0x011080 and code_point <= 0x0110c2);
    }
    if (isKaithiScriptExtensionsName(name)) return isUnicodeKaithiScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Kayah_Li") or
        std.mem.eql(u8, name, "Script=Kali") or
        std.mem.eql(u8, name, "sc=Kayah_Li") or
        std.mem.eql(u8, name, "sc=Kali"))
    {
        return code_point == 0x00a92f or
            (code_point >= 0x00a900 and code_point <= 0x00a92d);
    }
    if (std.mem.eql(u8, name, "Script_Extensions=Kayah_Li") or
        std.mem.eql(u8, name, "Script_Extensions=Kali") or
        std.mem.eql(u8, name, "scx=Kayah_Li") or
        std.mem.eql(u8, name, "scx=Kali"))
    {
        return code_point >= 0x00a900 and code_point <= 0x00a92f;
    }
    if (std.mem.eql(u8, name, "Script=Kannada") or
        std.mem.eql(u8, name, "Script=Knda") or
        std.mem.eql(u8, name, "sc=Kannada") or
        std.mem.eql(u8, name, "sc=Knda"))
    {
        return (code_point >= 0x000c80 and code_point <= 0x000c8c) or
            (code_point >= 0x000c8e and code_point <= 0x000c90) or
            (code_point >= 0x000c92 and code_point <= 0x000ca8) or
            (code_point >= 0x000caa and code_point <= 0x000cb3) or
            (code_point >= 0x000cb5 and code_point <= 0x000cb9) or
            (code_point >= 0x000cbc and code_point <= 0x000cc4) or
            (code_point >= 0x000cc6 and code_point <= 0x000cc8) or
            (code_point >= 0x000cca and code_point <= 0x000ccd) or
            (code_point >= 0x000cd5 and code_point <= 0x000cd6) or
            (code_point >= 0x000cdc and code_point <= 0x000cde) or
            (code_point >= 0x000ce0 and code_point <= 0x000ce3) or
            (code_point >= 0x000ce6 and code_point <= 0x000cef) or
            (code_point >= 0x000cf1 and code_point <= 0x000cf3);
    }
    if (isKannadaScriptExtensionsName(name)) return isUnicodeKannadaScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Katakana") or
        std.mem.eql(u8, name, "Script=Kana") or
        std.mem.eql(u8, name, "sc=Katakana") or
        std.mem.eql(u8, name, "sc=Kana"))
    {
        return code_point == 0x01b000 or
            code_point == 0x01b155 or
            (code_point >= 0x0030a1 and code_point <= 0x0030fa) or
            (code_point >= 0x0030fd and code_point <= 0x0030ff) or
            (code_point >= 0x0031f0 and code_point <= 0x0031ff) or
            (code_point >= 0x0032d0 and code_point <= 0x0032fe) or
            (code_point >= 0x003300 and code_point <= 0x003357) or
            (code_point >= 0x00ff66 and code_point <= 0x00ff6f) or
            (code_point >= 0x00ff71 and code_point <= 0x00ff9d) or
            (code_point >= 0x01aff0 and code_point <= 0x01aff3) or
            (code_point >= 0x01aff5 and code_point <= 0x01affb) or
            (code_point >= 0x01affd and code_point <= 0x01affe) or
            (code_point >= 0x01b120 and code_point <= 0x01b122) or
            (code_point >= 0x01b164 and code_point <= 0x01b167);
    }
    if (isKatakanaScriptExtensionsName(name)) return isUnicodeKatakanaScriptExtensionsCodePoint(code_point);
    if (isKhojkiScriptExtensionsName(name)) return isUnicodeKhojkiScriptExtensionsCodePoint(code_point);
    if (isKhudawadiScriptExtensionsName(name)) return isUnicodeKhudawadiScriptExtensionsCodePoint(code_point);
    if (isLatinScriptExtensionsName(name)) return isUnicodeLatinScriptExtensionsCodePoint(code_point);
    if (isLimbuScriptExtensionsName(name)) return isUnicodeLimbuScriptExtensionsCodePoint(code_point);
    if (isMalayalamScriptExtensionsName(name)) return isUnicodeMalayalamScriptExtensionsCodePoint(code_point);
    if (isMandaicScriptExtensionsName(name)) return isUnicodeMandaicScriptExtensionsCodePoint(code_point);
    if (isModiScriptExtensionsName(name)) return isUnicodeModiScriptExtensionsCodePoint(code_point);
    if (isMongolianScriptExtensionsName(name)) return isUnicodeMongolianScriptExtensionsCodePoint(code_point);
    if (isMyanmarScriptExtensionsName(name)) return isUnicodeMyanmarScriptExtensionsCodePoint(code_point);
    if (isNagMundariScriptExtensionsName(name)) return isUnicodeNagMundariScriptExtensionsCodePoint(code_point);
    if (isNandinagariScriptExtensionsName(name)) return isUnicodeNandinagariScriptExtensionsCodePoint(code_point);
    if (isNewaScriptExtensionsName(name)) return isUnicodeNewaScriptExtensionsCodePoint(code_point);
    if (isNewTaiLueScriptExtensionsName(name)) return isUnicodeNewTaiLueScriptExtensionsCodePoint(code_point);
    if (isNkoScriptExtensionsName(name)) return isUnicodeNkoScriptExtensionsCodePoint(code_point);
    if (isOldHungarianScriptExtensionsName(name)) return isUnicodeOldHungarianScriptExtensionsCodePoint(code_point);
    if (isOldPermicScriptExtensionsName(name)) return isUnicodeOldPermicScriptExtensionsCodePoint(code_point);
    if (isOldPersianScriptExtensionsName(name)) return isUnicodeOldPersianScriptExtensionsCodePoint(code_point);
    if (isOldSogdianScriptExtensionsName(name)) return isUnicodeOldSogdianScriptExtensionsCodePoint(code_point);
    if (isOldTurkicScriptExtensionsName(name)) return isUnicodeOldTurkicScriptExtensionsCodePoint(code_point);
    if (isOldUyghurScriptExtensionsName(name)) return isUnicodeOldUyghurScriptExtensionsCodePoint(code_point);
    if (isOriyaScriptExtensionsName(name)) return isUnicodeOriyaScriptExtensionsCodePoint(code_point);
    if (isOsageScriptExtensionsName(name)) return isUnicodeOsageScriptExtensionsCodePoint(code_point);
    if (isOsmanyaScriptExtensionsName(name)) return isUnicodeOsmanyaScriptExtensionsCodePoint(code_point);
    if (isPahawhHmongScriptExtensionsName(name)) return isUnicodePahawhHmongScriptExtensionsCodePoint(code_point);
    if (isPauCinHauScriptExtensionsName(name)) return isUnicodePauCinHauScriptExtensionsCodePoint(code_point);
    if (isPhagsPaScriptExtensionsName(name)) return isUnicodePhagsPaScriptExtensionsCodePoint(code_point);
    if (isPhoenicianScriptExtensionsName(name)) return isUnicodePhoenicianScriptExtensionsCodePoint(code_point);
    if (isPsalterPahlaviScriptExtensionsName(name)) return isUnicodePsalterPahlaviScriptExtensionsCodePoint(code_point);
    if (isRejangScriptExtensionsName(name)) return isUnicodeRejangScriptExtensionsCodePoint(code_point);
    if (isRunicScriptExtensionsName(name)) return isUnicodeRunicScriptExtensionsCodePoint(code_point);
    if (isSamaritanScriptExtensionsName(name)) return isUnicodeSamaritanScriptExtensionsCodePoint(code_point);
    if (isSaurashtraScriptExtensionsName(name)) return isUnicodeSaurashtraScriptExtensionsCodePoint(code_point);
    if (isSharadaScriptExtensionsName(name)) return isUnicodeSharadaScriptExtensionsCodePoint(code_point);
    if (isShavianScriptExtensionsName(name)) return isUnicodeShavianScriptExtensionsCodePoint(code_point);
    if (isSiddhamScriptExtensionsName(name)) return isUnicodeSiddhamScriptExtensionsCodePoint(code_point);
    if (isSideticScriptExtensionsName(name)) return isUnicodeSideticScriptExtensionsCodePoint(code_point);
    if (isSinhalaScriptExtensionsName(name)) return isUnicodeSinhalaScriptExtensionsCodePoint(code_point);
    if (isSogdianScriptExtensionsName(name)) return isUnicodeSogdianScriptExtensionsCodePoint(code_point);
    if (isSoyomboScriptExtensionsName(name)) return isUnicodeSoyomboScriptExtensionsCodePoint(code_point);
    if (isSundaneseScriptExtensionsName(name)) return isUnicodeSundaneseScriptExtensionsCodePoint(code_point);
    if (isSunuwarScriptExtensionsName(name)) return isUnicodeSunuwarScriptExtensionsCodePoint(code_point);
    if (isSylotiNagriScriptExtensionsName(name)) return isUnicodeSylotiNagriScriptExtensionsCodePoint(code_point);
    if (isSyriacScriptExtensionsName(name)) return isUnicodeSyriacScriptExtensionsCodePoint(code_point);
    if (isTagalogScriptExtensionsName(name)) return isUnicodeTagalogScriptExtensionsCodePoint(code_point);
    if (isTagbanwaScriptExtensionsName(name)) return isUnicodeTagbanwaScriptExtensionsCodePoint(code_point);
    if (isTaiLeScriptExtensionsName(name)) return isUnicodeTaiLeScriptExtensionsCodePoint(code_point);
    if (isTakriScriptExtensionsName(name)) return isUnicodeTakriScriptExtensionsCodePoint(code_point);
    if (isTangutScriptExtensionsName(name)) return isUnicodeTangutScriptExtensionsCodePoint(code_point);
    if (isTeluguScriptExtensionsName(name)) return isUnicodeTeluguScriptExtensionsCodePoint(code_point);
    if (isThaanaScriptExtensionsName(name)) return isUnicodeThaanaScriptExtensionsCodePoint(code_point);
    if (isThaiScriptExtensionsName(name)) return isUnicodeThaiScriptExtensionsCodePoint(code_point);
    if (isTibetanScriptExtensionsName(name)) return isUnicodeTibetanScriptExtensionsCodePoint(code_point);
    if (isTifinaghScriptExtensionsName(name)) return isUnicodeTifinaghScriptExtensionsCodePoint(code_point);
    if (isTirhutaScriptExtensionsName(name)) return isUnicodeTirhutaScriptExtensionsCodePoint(code_point);
    if (isTodhriScriptExtensionsName(name)) return isUnicodeTodhriScriptExtensionsCodePoint(code_point);
    if (isTotoScriptExtensionsName(name)) return isUnicodeTotoScriptExtensionsCodePoint(code_point);
    if (isTuluTigalariScriptExtensionsName(name)) return isUnicodeTuluTigalariScriptExtensionsCodePoint(code_point);
    if (isYezidiScriptExtensionsName(name)) return isUnicodeYezidiScriptExtensionsCodePoint(code_point);
    if (isYiScriptExtensionsName(name)) return isUnicodeYiScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Kawi") or
        std.mem.eql(u8, name, "sc=Kawi") or
        std.mem.eql(u8, name, "Script_Extensions=Kawi") or
        std.mem.eql(u8, name, "scx=Kawi"))
    {
        return (code_point >= 0x011f00 and code_point <= 0x011f10) or
            (code_point >= 0x011f12 and code_point <= 0x011f3a) or
            (code_point >= 0x011f3e and code_point <= 0x011f5a);
    }
    if (std.mem.eql(u8, name, "Script=Kharoshthi") or
        std.mem.eql(u8, name, "Script=Khar") or
        std.mem.eql(u8, name, "sc=Kharoshthi") or
        std.mem.eql(u8, name, "sc=Khar"))
    {
        return (code_point >= 0x010a00 and code_point <= 0x010a03) or
            (code_point >= 0x010a05 and code_point <= 0x010a06) or
            (code_point >= 0x010a0c and code_point <= 0x010a13) or
            (code_point >= 0x010a15 and code_point <= 0x010a17) or
            (code_point >= 0x010a19 and code_point <= 0x010a35) or
            (code_point >= 0x010a38 and code_point <= 0x010a3a) or
            (code_point >= 0x010a3f and code_point <= 0x010a48) or
            (code_point >= 0x010a50 and code_point <= 0x010a58);
    }
    if (std.mem.eql(u8, name, "Script=Khitan_Small_Script") or
        std.mem.eql(u8, name, "Script=Kits") or
        std.mem.eql(u8, name, "sc=Khitan_Small_Script") or
        std.mem.eql(u8, name, "sc=Kits"))
    {
        return code_point == 0x016fe4 or
            code_point == 0x018cff or
            (code_point >= 0x018b00 and code_point <= 0x018cd5);
    }
    if (std.mem.eql(u8, name, "Script=Khojki") or
        std.mem.eql(u8, name, "Script=Khoj") or
        std.mem.eql(u8, name, "sc=Khojki") or
        std.mem.eql(u8, name, "sc=Khoj"))
    {
        return (code_point >= 0x011200 and code_point <= 0x011211) or
            (code_point >= 0x011213 and code_point <= 0x011241);
    }
    if (std.mem.eql(u8, name, "Script=Khmer") or
        std.mem.eql(u8, name, "Script=Khmr") or
        std.mem.eql(u8, name, "sc=Khmer") or
        std.mem.eql(u8, name, "sc=Khmr"))
    {
        return (code_point >= 0x001780 and code_point <= 0x0017dd) or
            (code_point >= 0x0017e0 and code_point <= 0x0017e9) or
            (code_point >= 0x0017f0 and code_point <= 0x0017f9) or
            (code_point >= 0x0019e0 and code_point <= 0x0019ff);
    }
    if (std.mem.eql(u8, name, "Script=Kirat_Rai") or
        std.mem.eql(u8, name, "Script=Krai") or
        std.mem.eql(u8, name, "sc=Kirat_Rai") or
        std.mem.eql(u8, name, "sc=Krai"))
    {
        return code_point >= 0x016d40 and code_point <= 0x016d79;
    }
    if (std.mem.eql(u8, name, "Script=Khudawadi") or
        std.mem.eql(u8, name, "Script=Sind") or
        std.mem.eql(u8, name, "sc=Khudawadi") or
        std.mem.eql(u8, name, "sc=Sind"))
    {
        return (code_point >= 0x0112b0 and code_point <= 0x0112ea) or
            (code_point >= 0x0112f0 and code_point <= 0x0112f9);
    }
    if (std.mem.eql(u8, name, "Script=Lao") or
        std.mem.eql(u8, name, "Script=Laoo") or
        std.mem.eql(u8, name, "sc=Lao") or
        std.mem.eql(u8, name, "sc=Laoo") or
        std.mem.eql(u8, name, "Script_Extensions=Lao") or
        std.mem.eql(u8, name, "Script_Extensions=Laoo") or
        std.mem.eql(u8, name, "scx=Lao") or
        std.mem.eql(u8, name, "scx=Laoo"))
    {
        return code_point == 0x000e84 or
            code_point == 0x000ea5 or
            code_point == 0x000ec6 or
            (code_point >= 0x000e81 and code_point <= 0x000e82) or
            (code_point >= 0x000e86 and code_point <= 0x000e8a) or
            (code_point >= 0x000e8c and code_point <= 0x000ea3) or
            (code_point >= 0x000ea7 and code_point <= 0x000ebd) or
            (code_point >= 0x000ec0 and code_point <= 0x000ec4) or
            (code_point >= 0x000ec8 and code_point <= 0x000ece) or
            (code_point >= 0x000ed0 and code_point <= 0x000ed9) or
            (code_point >= 0x000edc and code_point <= 0x000edf);
    }
    if (std.mem.eql(u8, name, "Script=Lepcha") or
        std.mem.eql(u8, name, "Script=Lepc") or
        std.mem.eql(u8, name, "sc=Lepcha") or
        std.mem.eql(u8, name, "sc=Lepc"))
    {
        return (code_point >= 0x001c00 and code_point <= 0x001c37) or
            (code_point >= 0x001c3b and code_point <= 0x001c49) or
            (code_point >= 0x001c4d and code_point <= 0x001c4f);
    }
    if (std.mem.eql(u8, name, "Script=Limbu") or
        std.mem.eql(u8, name, "Script=Limb") or
        std.mem.eql(u8, name, "sc=Limbu") or
        std.mem.eql(u8, name, "sc=Limb"))
    {
        return code_point == 0x001940 or
            (code_point >= 0x001900 and code_point <= 0x00191e) or
            (code_point >= 0x001920 and code_point <= 0x00192b) or
            (code_point >= 0x001930 and code_point <= 0x00193b) or
            (code_point >= 0x001944 and code_point <= 0x00194f);
    }
    if (std.mem.eql(u8, name, "Script=Linear_A") or
        std.mem.eql(u8, name, "Script=Lina") or
        std.mem.eql(u8, name, "sc=Linear_A") or
        std.mem.eql(u8, name, "sc=Lina"))
    {
        return (code_point >= 0x010600 and code_point <= 0x010736) or
            (code_point >= 0x010740 and code_point <= 0x010755) or
            (code_point >= 0x010760 and code_point <= 0x010767);
    }
    if (std.mem.eql(u8, name, "Script=Linear_B") or
        std.mem.eql(u8, name, "Script=Linb") or
        std.mem.eql(u8, name, "sc=Linear_B") or
        std.mem.eql(u8, name, "sc=Linb"))
    {
        return (code_point >= 0x010000 and code_point <= 0x01000b) or
            (code_point >= 0x01000d and code_point <= 0x010026) or
            (code_point >= 0x010028 and code_point <= 0x01003a) or
            (code_point >= 0x01003c and code_point <= 0x01003d) or
            (code_point >= 0x01003f and code_point <= 0x01004d) or
            (code_point >= 0x010050 and code_point <= 0x01005d) or
            (code_point >= 0x010080 and code_point <= 0x0100fa);
    }
    if (std.mem.eql(u8, name, "Script=Lycian") or
        std.mem.eql(u8, name, "Script=Lyci") or
        std.mem.eql(u8, name, "sc=Lycian") or
        std.mem.eql(u8, name, "sc=Lyci"))
    {
        return code_point >= 0x010280 and code_point <= 0x01029c;
    }
    if (std.mem.eql(u8, name, "Script_Extensions=Lycian") or
        std.mem.eql(u8, name, "Script_Extensions=Lyci") or
        std.mem.eql(u8, name, "scx=Lycian") or
        std.mem.eql(u8, name, "scx=Lyci"))
    {
        return code_point == 0x00205a or
            (code_point >= 0x010280 and code_point <= 0x01029c);
    }
    if (std.mem.eql(u8, name, "Script=Lydian") or
        std.mem.eql(u8, name, "Script=Lydi") or
        std.mem.eql(u8, name, "sc=Lydian") or
        std.mem.eql(u8, name, "sc=Lydi"))
    {
        return code_point == 0x01093f or
            (code_point >= 0x010920 and code_point <= 0x010939);
    }
    if (std.mem.eql(u8, name, "Script=Lisu") or std.mem.eql(u8, name, "sc=Lisu")) {
        return code_point == 0x011fb0 or
            (code_point >= 0x00a4d0 and code_point <= 0x00a4ff);
    }
    if (std.mem.eql(u8, name, "Script=Latin") or
        std.mem.eql(u8, name, "Script=Latn") or
        std.mem.eql(u8, name, "sc=Latin") or
        std.mem.eql(u8, name, "sc=Latn"))
    {
        return code_point == 0x0000aa or
            code_point == 0x0000ba or
            code_point == 0x002071 or
            code_point == 0x00207f or
            code_point == 0x002132 or
            code_point == 0x00214e or
            (code_point >= 0x000041 and code_point <= 0x00005a) or
            (code_point >= 0x000061 and code_point <= 0x00007a) or
            (code_point >= 0x0000c0 and code_point <= 0x0000d6) or
            (code_point >= 0x0000d8 and code_point <= 0x0000f6) or
            (code_point >= 0x0000f8 and code_point <= 0x0002b8) or
            (code_point >= 0x0002e0 and code_point <= 0x0002e4) or
            (code_point >= 0x001d00 and code_point <= 0x001d25) or
            (code_point >= 0x001d2c and code_point <= 0x001d5c) or
            (code_point >= 0x001d62 and code_point <= 0x001d65) or
            (code_point >= 0x001d6b and code_point <= 0x001d77) or
            (code_point >= 0x001d79 and code_point <= 0x001dbe) or
            (code_point >= 0x001e00 and code_point <= 0x001eff) or
            (code_point >= 0x002090 and code_point <= 0x00209c) or
            (code_point >= 0x00212a and code_point <= 0x00212b) or
            (code_point >= 0x002160 and code_point <= 0x002188) or
            (code_point >= 0x002c60 and code_point <= 0x002c7f) or
            (code_point >= 0x00a722 and code_point <= 0x00a787) or
            (code_point >= 0x00a78b and code_point <= 0x00a7dc) or
            (code_point >= 0x00a7f1 and code_point <= 0x00a7ff) or
            (code_point >= 0x00ab30 and code_point <= 0x00ab5a) or
            (code_point >= 0x00ab5c and code_point <= 0x00ab64) or
            (code_point >= 0x00ab66 and code_point <= 0x00ab69) or
            (code_point >= 0x00fb00 and code_point <= 0x00fb06) or
            (code_point >= 0x00ff21 and code_point <= 0x00ff3a) or
            (code_point >= 0x00ff41 and code_point <= 0x00ff5a) or
            (code_point >= 0x010780 and code_point <= 0x010785) or
            (code_point >= 0x010787 and code_point <= 0x0107b0) or
            (code_point >= 0x0107b2 and code_point <= 0x0107ba) or
            (code_point >= 0x01df00 and code_point <= 0x01df1e) or
            (code_point >= 0x01df25 and code_point <= 0x01df2a);
    }
    if (std.mem.eql(u8, name, "Script=Mahajani") or
        std.mem.eql(u8, name, "Script=Mahj") or
        std.mem.eql(u8, name, "sc=Mahajani") or
        std.mem.eql(u8, name, "sc=Mahj"))
    {
        return code_point >= 0x011150 and code_point <= 0x011176;
    }
    if (std.mem.eql(u8, name, "Script=Makasar") or
        std.mem.eql(u8, name, "Script=Maka") or
        std.mem.eql(u8, name, "sc=Makasar") or
        std.mem.eql(u8, name, "sc=Maka"))
    {
        return code_point >= 0x011ee0 and code_point <= 0x011ef8;
    }
    if (std.mem.eql(u8, name, "Script=Malayalam") or
        std.mem.eql(u8, name, "Script=Mlym") or
        std.mem.eql(u8, name, "sc=Malayalam") or
        std.mem.eql(u8, name, "sc=Mlym"))
    {
        return (code_point >= 0x000d00 and code_point <= 0x000d0c) or
            (code_point >= 0x000d0e and code_point <= 0x000d10) or
            (code_point >= 0x000d12 and code_point <= 0x000d44) or
            (code_point >= 0x000d46 and code_point <= 0x000d48) or
            (code_point >= 0x000d4a and code_point <= 0x000d4f) or
            (code_point >= 0x000d54 and code_point <= 0x000d63) or
            (code_point >= 0x000d66 and code_point <= 0x000d7f);
    }
    if (std.mem.eql(u8, name, "Script=Masaram_Gondi") or
        std.mem.eql(u8, name, "Script=Gonm") or
        std.mem.eql(u8, name, "sc=Masaram_Gondi") or
        std.mem.eql(u8, name, "sc=Gonm"))
    {
        return code_point == 0x011d3a or
            (code_point >= 0x011d00 and code_point <= 0x011d06) or
            (code_point >= 0x011d08 and code_point <= 0x011d09) or
            (code_point >= 0x011d0b and code_point <= 0x011d36) or
            (code_point >= 0x011d3c and code_point <= 0x011d3d) or
            (code_point >= 0x011d3f and code_point <= 0x011d47) or
            (code_point >= 0x011d50 and code_point <= 0x011d59);
    }
    if (std.mem.eql(u8, name, "Script=Mandaic") or
        std.mem.eql(u8, name, "Script=Mand") or
        std.mem.eql(u8, name, "sc=Mandaic") or
        std.mem.eql(u8, name, "sc=Mand"))
    {
        return code_point == 0x00085e or
            (code_point >= 0x000840 and code_point <= 0x00085b);
    }
    if (std.mem.eql(u8, name, "Script=Manichaean") or
        std.mem.eql(u8, name, "Script=Mani") or
        std.mem.eql(u8, name, "sc=Manichaean") or
        std.mem.eql(u8, name, "sc=Mani"))
    {
        return (code_point >= 0x010ac0 and code_point <= 0x010ae6) or
            (code_point >= 0x010aeb and code_point <= 0x010af6);
    }
    if (std.mem.eql(u8, name, "Script=Marchen") or
        std.mem.eql(u8, name, "Script=Marc") or
        std.mem.eql(u8, name, "sc=Marchen") or
        std.mem.eql(u8, name, "sc=Marc"))
    {
        return (code_point >= 0x011c70 and code_point <= 0x011c8f) or
            (code_point >= 0x011c92 and code_point <= 0x011ca7) or
            (code_point >= 0x011ca9 and code_point <= 0x011cb6);
    }
    if (std.mem.eql(u8, name, "Script=Medefaidrin") or
        std.mem.eql(u8, name, "Script=Medf") or
        std.mem.eql(u8, name, "sc=Medefaidrin") or
        std.mem.eql(u8, name, "sc=Medf"))
    {
        return code_point >= 0x016e40 and code_point <= 0x016e9a;
    }
    if (std.mem.eql(u8, name, "Script=Meetei_Mayek") or
        std.mem.eql(u8, name, "Script=Mtei") or
        std.mem.eql(u8, name, "sc=Meetei_Mayek") or
        std.mem.eql(u8, name, "sc=Mtei"))
    {
        return (code_point >= 0x00aae0 and code_point <= 0x00aaf6) or
            (code_point >= 0x00abc0 and code_point <= 0x00abed) or
            (code_point >= 0x00abf0 and code_point <= 0x00abf9);
    }
    if (std.mem.eql(u8, name, "Script=Mende_Kikakui") or
        std.mem.eql(u8, name, "Script=Mend") or
        std.mem.eql(u8, name, "sc=Mende_Kikakui") or
        std.mem.eql(u8, name, "sc=Mend"))
    {
        return (code_point >= 0x01e800 and code_point <= 0x01e8c4) or
            (code_point >= 0x01e8c7 and code_point <= 0x01e8d6);
    }
    if (std.mem.eql(u8, name, "Script=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "Script=Mero") or
        std.mem.eql(u8, name, "sc=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "sc=Mero"))
    {
        return code_point >= 0x010980 and code_point <= 0x01099f;
    }
    if (std.mem.eql(u8, name, "Script_Extensions=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "Script_Extensions=Mero") or
        std.mem.eql(u8, name, "scx=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "scx=Mero"))
    {
        return code_point == 0x00205d or
            (code_point >= 0x010980 and code_point <= 0x01099f);
    }
    if (std.mem.eql(u8, name, "Script=Meroitic_Cursive") or
        std.mem.eql(u8, name, "Script=Merc") or
        std.mem.eql(u8, name, "sc=Meroitic_Cursive") or
        std.mem.eql(u8, name, "sc=Merc"))
    {
        return (code_point >= 0x0109a0 and code_point <= 0x0109b7) or
            (code_point >= 0x0109bc and code_point <= 0x0109cf) or
            (code_point >= 0x0109d2 and code_point <= 0x0109ff);
    }
    if (std.mem.eql(u8, name, "Script=Miao") or
        std.mem.eql(u8, name, "Script=Plrd") or
        std.mem.eql(u8, name, "sc=Miao") or
        std.mem.eql(u8, name, "sc=Plrd"))
    {
        return (code_point >= 0x016f00 and code_point <= 0x016f4a) or
            (code_point >= 0x016f4f and code_point <= 0x016f87) or
            (code_point >= 0x016f8f and code_point <= 0x016f9f);
    }
    if (std.mem.eql(u8, name, "Script=Modi") or std.mem.eql(u8, name, "sc=Modi")) {
        return (code_point >= 0x011600 and code_point <= 0x011644) or
            (code_point >= 0x011650 and code_point <= 0x011659);
    }
    if (std.mem.eql(u8, name, "Script=Mongolian") or
        std.mem.eql(u8, name, "Script=Mong") or
        std.mem.eql(u8, name, "sc=Mongolian") or
        std.mem.eql(u8, name, "sc=Mong"))
    {
        return code_point == 0x001804 or
            (code_point >= 0x001800 and code_point <= 0x001801) or
            (code_point >= 0x001806 and code_point <= 0x001819) or
            (code_point >= 0x001820 and code_point <= 0x001878) or
            (code_point >= 0x001880 and code_point <= 0x0018aa) or
            (code_point >= 0x011660 and code_point <= 0x01166c);
    }
    if (std.mem.eql(u8, name, "Script=Multani") or
        std.mem.eql(u8, name, "Script=Mult") or
        std.mem.eql(u8, name, "sc=Multani") or
        std.mem.eql(u8, name, "sc=Mult"))
    {
        return code_point == 0x011288 or
            (code_point >= 0x011280 and code_point <= 0x011286) or
            (code_point >= 0x01128a and code_point <= 0x01128d) or
            (code_point >= 0x01128f and code_point <= 0x01129d) or
            (code_point >= 0x01129f and code_point <= 0x0112a9);
    }
    if (std.mem.eql(u8, name, "Script=Myanmar") or
        std.mem.eql(u8, name, "Script=Mymr") or
        std.mem.eql(u8, name, "sc=Myanmar") or
        std.mem.eql(u8, name, "sc=Mymr"))
    {
        return (code_point >= 0x001000 and code_point <= 0x00109f) or
            (code_point >= 0x00a9e0 and code_point <= 0x00a9fe) or
            (code_point >= 0x00aa60 and code_point <= 0x00aa7f) or
            (code_point >= 0x0116d0 and code_point <= 0x0116e3);
    }
    if (std.mem.eql(u8, name, "Script=Mro") or
        std.mem.eql(u8, name, "Script=Mroo") or
        std.mem.eql(u8, name, "sc=Mro") or
        std.mem.eql(u8, name, "sc=Mroo"))
    {
        return (code_point >= 0x016a40 and code_point <= 0x016a5e) or
            (code_point >= 0x016a60 and code_point <= 0x016a69) or
            (code_point >= 0x016a6e and code_point <= 0x016a6f);
    }
    if (std.mem.eql(u8, name, "Script=Nag_Mundari") or
        std.mem.eql(u8, name, "Script=Nagm") or
        std.mem.eql(u8, name, "sc=Nag_Mundari") or
        std.mem.eql(u8, name, "sc=Nagm"))
    {
        return code_point >= 0x01e4d0 and code_point <= 0x01e4f9;
    }
    if (std.mem.eql(u8, name, "Script=Nabataean") or
        std.mem.eql(u8, name, "Script=Nbat") or
        std.mem.eql(u8, name, "sc=Nabataean") or
        std.mem.eql(u8, name, "sc=Nbat"))
    {
        return (code_point >= 0x010880 and code_point <= 0x01089e) or
            (code_point >= 0x0108a7 and code_point <= 0x0108af);
    }
    if (std.mem.eql(u8, name, "Script=Nandinagari") or
        std.mem.eql(u8, name, "Script=Nand") or
        std.mem.eql(u8, name, "sc=Nandinagari") or
        std.mem.eql(u8, name, "sc=Nand"))
    {
        return (code_point >= 0x0119a0 and code_point <= 0x0119a7) or
            (code_point >= 0x0119aa and code_point <= 0x0119d7) or
            (code_point >= 0x0119da and code_point <= 0x0119e4);
    }
    if (std.mem.eql(u8, name, "Script=Newa") or std.mem.eql(u8, name, "sc=Newa")) {
        return (code_point >= 0x011400 and code_point <= 0x01145b) or
            (code_point >= 0x01145d and code_point <= 0x011461);
    }
    if (std.mem.eql(u8, name, "Script=New_Tai_Lue") or
        std.mem.eql(u8, name, "Script=Talu") or
        std.mem.eql(u8, name, "sc=New_Tai_Lue") or
        std.mem.eql(u8, name, "sc=Talu"))
    {
        return (code_point >= 0x001980 and code_point <= 0x0019ab) or
            (code_point >= 0x0019b0 and code_point <= 0x0019c9) or
            (code_point >= 0x0019d0 and code_point <= 0x0019da) or
            (code_point >= 0x0019de and code_point <= 0x0019df);
    }
    if (std.mem.eql(u8, name, "Script=Nko") or
        std.mem.eql(u8, name, "Script=Nkoo") or
        std.mem.eql(u8, name, "sc=Nko") or
        std.mem.eql(u8, name, "sc=Nkoo"))
    {
        return (code_point >= 0x0007c0 and code_point <= 0x0007fa) or
            (code_point >= 0x0007fd and code_point <= 0x0007ff);
    }
    if (std.mem.eql(u8, name, "Script=Nushu") or
        std.mem.eql(u8, name, "Script=Nshu") or
        std.mem.eql(u8, name, "sc=Nushu") or
        std.mem.eql(u8, name, "sc=Nshu"))
    {
        return code_point == 0x016fe1 or
            (code_point >= 0x01b170 and code_point <= 0x01b2fb);
    }
    if (std.mem.eql(u8, name, "Script=Nyiakeng_Puachue_Hmong") or
        std.mem.eql(u8, name, "Script=Hmnp") or
        std.mem.eql(u8, name, "sc=Nyiakeng_Puachue_Hmong") or
        std.mem.eql(u8, name, "sc=Hmnp"))
    {
        return (code_point >= 0x01e100 and code_point <= 0x01e12c) or
            (code_point >= 0x01e130 and code_point <= 0x01e13d) or
            (code_point >= 0x01e140 and code_point <= 0x01e149) or
            (code_point >= 0x01e14e and code_point <= 0x01e14f);
    }
    if (std.mem.eql(u8, name, "Script=Ogham") or
        std.mem.eql(u8, name, "Script=Ogam") or
        std.mem.eql(u8, name, "sc=Ogham") or
        std.mem.eql(u8, name, "sc=Ogam"))
    {
        return code_point >= 0x001680 and code_point <= 0x00169c;
    }
    if (std.mem.eql(u8, name, "Script=Ol_Chiki") or
        std.mem.eql(u8, name, "Script=Olck") or
        std.mem.eql(u8, name, "sc=Ol_Chiki") or
        std.mem.eql(u8, name, "sc=Olck"))
    {
        return code_point >= 0x001c50 and code_point <= 0x001c7f;
    }
    if (std.mem.eql(u8, name, "Script=Ol_Onal") or
        std.mem.eql(u8, name, "Script=Onao") or
        std.mem.eql(u8, name, "sc=Ol_Onal") or
        std.mem.eql(u8, name, "sc=Onao"))
    {
        return code_point == 0x01e5ff or
            (code_point >= 0x01e5d0 and code_point <= 0x01e5fa);
    }
    if (std.mem.eql(u8, name, "Script=Old_Italic") or
        std.mem.eql(u8, name, "Script=Ital") or
        std.mem.eql(u8, name, "sc=Old_Italic") or
        std.mem.eql(u8, name, "sc=Ital"))
    {
        return (code_point >= 0x010300 and code_point <= 0x010323) or
            (code_point >= 0x01032d and code_point <= 0x01032f);
    }
    if (std.mem.eql(u8, name, "Script=Old_North_Arabian") or
        std.mem.eql(u8, name, "Script=Narb") or
        std.mem.eql(u8, name, "sc=Old_North_Arabian") or
        std.mem.eql(u8, name, "sc=Narb"))
    {
        return code_point >= 0x010a80 and code_point <= 0x010a9f;
    }
    if (std.mem.eql(u8, name, "Script=Old_Sogdian") or
        std.mem.eql(u8, name, "Script=Sogo") or
        std.mem.eql(u8, name, "sc=Old_Sogdian") or
        std.mem.eql(u8, name, "sc=Sogo"))
    {
        return code_point >= 0x010f00 and code_point <= 0x010f27;
    }
    if (std.mem.eql(u8, name, "Script=Old_South_Arabian") or
        std.mem.eql(u8, name, "Script=Sarb") or
        std.mem.eql(u8, name, "sc=Old_South_Arabian") or
        std.mem.eql(u8, name, "sc=Sarb"))
    {
        return code_point >= 0x010a60 and code_point <= 0x010a7f;
    }
    if (std.mem.eql(u8, name, "Script=Old_Hungarian") or
        std.mem.eql(u8, name, "Script=Hung") or
        std.mem.eql(u8, name, "sc=Old_Hungarian") or
        std.mem.eql(u8, name, "sc=Hung"))
    {
        return (code_point >= 0x010c80 and code_point <= 0x010cb2) or
            (code_point >= 0x010cc0 and code_point <= 0x010cf2) or
            (code_point >= 0x010cfa and code_point <= 0x010cff);
    }
    if (std.mem.eql(u8, name, "Script=Old_Permic") or
        std.mem.eql(u8, name, "Script=Perm") or
        std.mem.eql(u8, name, "sc=Old_Permic") or
        std.mem.eql(u8, name, "sc=Perm"))
    {
        return code_point >= 0x010350 and code_point <= 0x01037a;
    }
    if (std.mem.eql(u8, name, "Script=Old_Uyghur") or
        std.mem.eql(u8, name, "Script=Ougr") or
        std.mem.eql(u8, name, "sc=Old_Uyghur") or
        std.mem.eql(u8, name, "sc=Ougr"))
    {
        return code_point >= 0x010f70 and code_point <= 0x010f89;
    }
    if (std.mem.eql(u8, name, "Script=Old_Turkic") or
        std.mem.eql(u8, name, "Script=Orkh") or
        std.mem.eql(u8, name, "sc=Old_Turkic") or
        std.mem.eql(u8, name, "sc=Orkh"))
    {
        return code_point >= 0x010c00 and code_point <= 0x010c48;
    }
    if (std.mem.eql(u8, name, "Script=Old_Persian") or
        std.mem.eql(u8, name, "Script=Xpeo") or
        std.mem.eql(u8, name, "sc=Old_Persian") or
        std.mem.eql(u8, name, "sc=Xpeo"))
    {
        return (code_point >= 0x0103a0 and code_point <= 0x0103c3) or
            (code_point >= 0x0103c8 and code_point <= 0x0103d5);
    }
    if (std.mem.eql(u8, name, "Script=Osmanya") or
        std.mem.eql(u8, name, "Script=Osma") or
        std.mem.eql(u8, name, "sc=Osmanya") or
        std.mem.eql(u8, name, "sc=Osma"))
    {
        return (code_point >= 0x010480 and code_point <= 0x01049d) or
            (code_point >= 0x0104a0 and code_point <= 0x0104a9);
    }
    if (std.mem.eql(u8, name, "Script=Oriya") or
        std.mem.eql(u8, name, "Script=Orya") or
        std.mem.eql(u8, name, "sc=Oriya") or
        std.mem.eql(u8, name, "sc=Orya"))
    {
        return (code_point >= 0x000b01 and code_point <= 0x000b03) or
            (code_point >= 0x000b05 and code_point <= 0x000b0c) or
            (code_point >= 0x000b0f and code_point <= 0x000b10) or
            (code_point >= 0x000b13 and code_point <= 0x000b28) or
            (code_point >= 0x000b2a and code_point <= 0x000b30) or
            (code_point >= 0x000b32 and code_point <= 0x000b33) or
            (code_point >= 0x000b35 and code_point <= 0x000b39) or
            (code_point >= 0x000b3c and code_point <= 0x000b44) or
            (code_point >= 0x000b47 and code_point <= 0x000b48) or
            (code_point >= 0x000b4b and code_point <= 0x000b4d) or
            (code_point >= 0x000b55 and code_point <= 0x000b57) or
            (code_point >= 0x000b5c and code_point <= 0x000b5d) or
            (code_point >= 0x000b5f and code_point <= 0x000b63) or
            (code_point >= 0x000b66 and code_point <= 0x000b77);
    }
    if (std.mem.eql(u8, name, "Script=Osage") or
        std.mem.eql(u8, name, "Script=Osge") or
        std.mem.eql(u8, name, "sc=Osage") or
        std.mem.eql(u8, name, "sc=Osge"))
    {
        return (code_point >= 0x0104b0 and code_point <= 0x0104d3) or
            (code_point >= 0x0104d8 and code_point <= 0x0104fb);
    }
    if (std.mem.eql(u8, name, "Script=Palmyrene") or
        std.mem.eql(u8, name, "Script=Palm") or
        std.mem.eql(u8, name, "sc=Palmyrene") or
        std.mem.eql(u8, name, "sc=Palm"))
    {
        return code_point >= 0x010860 and code_point <= 0x01087f;
    }
    if (std.mem.eql(u8, name, "Script=Pahawh_Hmong") or
        std.mem.eql(u8, name, "Script=Hmng") or
        std.mem.eql(u8, name, "sc=Pahawh_Hmong") or
        std.mem.eql(u8, name, "sc=Hmng"))
    {
        return (code_point >= 0x016b00 and code_point <= 0x016b45) or
            (code_point >= 0x016b50 and code_point <= 0x016b59) or
            (code_point >= 0x016b5b and code_point <= 0x016b61) or
            (code_point >= 0x016b63 and code_point <= 0x016b77) or
            (code_point >= 0x016b7d and code_point <= 0x016b8f);
    }
    if (std.mem.eql(u8, name, "Script=Pau_Cin_Hau") or
        std.mem.eql(u8, name, "Script=Pauc") or
        std.mem.eql(u8, name, "sc=Pau_Cin_Hau") or
        std.mem.eql(u8, name, "sc=Pauc"))
    {
        return code_point >= 0x011ac0 and code_point <= 0x011af8;
    }
    if (std.mem.eql(u8, name, "Script=Phags_Pa") or
        std.mem.eql(u8, name, "Script=Phag") or
        std.mem.eql(u8, name, "sc=Phags_Pa") or
        std.mem.eql(u8, name, "sc=Phag"))
    {
        return code_point >= 0x00a840 and code_point <= 0x00a877;
    }
    if (std.mem.eql(u8, name, "Script=Phoenician") or
        std.mem.eql(u8, name, "Script=Phnx") or
        std.mem.eql(u8, name, "sc=Phoenician") or
        std.mem.eql(u8, name, "sc=Phnx"))
    {
        return code_point == 0x01091f or
            (code_point >= 0x010900 and code_point <= 0x01091b);
    }
    if (std.mem.eql(u8, name, "Script=Psalter_Pahlavi") or
        std.mem.eql(u8, name, "Script=Phlp") or
        std.mem.eql(u8, name, "sc=Psalter_Pahlavi") or
        std.mem.eql(u8, name, "sc=Phlp"))
    {
        return (code_point >= 0x010b80 and code_point <= 0x010b91) or
            (code_point >= 0x010b99 and code_point <= 0x010b9c) or
            (code_point >= 0x010ba9 and code_point <= 0x010baf);
    }
    if (std.mem.eql(u8, name, "Script=Rejang") or
        std.mem.eql(u8, name, "Script=Rjng") or
        std.mem.eql(u8, name, "sc=Rejang") or
        std.mem.eql(u8, name, "sc=Rjng"))
    {
        return code_point == 0x00a95f or
            (code_point >= 0x00a930 and code_point <= 0x00a953);
    }
    if (std.mem.eql(u8, name, "Script=Runic") or
        std.mem.eql(u8, name, "Script=Runr") or
        std.mem.eql(u8, name, "sc=Runic") or
        std.mem.eql(u8, name, "sc=Runr"))
    {
        return (code_point >= 0x0016a0 and code_point <= 0x0016ea) or
            (code_point >= 0x0016ee and code_point <= 0x0016f8);
    }
    if (std.mem.eql(u8, name, "Script_Extensions=Runic") or
        std.mem.eql(u8, name, "Script_Extensions=Runr") or
        std.mem.eql(u8, name, "scx=Runic") or
        std.mem.eql(u8, name, "scx=Runr"))
    {
        return code_point >= 0x0016a0 and code_point <= 0x0016f8;
    }
    if (std.mem.eql(u8, name, "Script=Saurashtra") or
        std.mem.eql(u8, name, "Script=Saur") or
        std.mem.eql(u8, name, "sc=Saurashtra") or
        std.mem.eql(u8, name, "sc=Saur"))
    {
        return (code_point >= 0x00a880 and code_point <= 0x00a8c5) or
            (code_point >= 0x00a8ce and code_point <= 0x00a8d9);
    }
    if (std.mem.eql(u8, name, "Script=Shavian") or
        std.mem.eql(u8, name, "Script=Shaw") or
        std.mem.eql(u8, name, "sc=Shavian") or
        std.mem.eql(u8, name, "sc=Shaw"))
    {
        return code_point >= 0x010450 and code_point <= 0x01047f;
    }
    if (std.mem.eql(u8, name, "Script_Extensions=Shavian") or
        std.mem.eql(u8, name, "Script_Extensions=Shaw") or
        std.mem.eql(u8, name, "scx=Shavian") or
        std.mem.eql(u8, name, "scx=Shaw"))
    {
        return code_point == 0x0000b7 or
            (code_point >= 0x010450 and code_point <= 0x01047f);
    }
    if (std.mem.eql(u8, name, "Script=Sharada") or
        std.mem.eql(u8, name, "Script=Shrd") or
        std.mem.eql(u8, name, "sc=Sharada") or
        std.mem.eql(u8, name, "sc=Shrd"))
    {
        return (code_point >= 0x011180 and code_point <= 0x0111df) or
            (code_point >= 0x011b60 and code_point <= 0x011b67);
    }
    if (std.mem.eql(u8, name, "Script=Samaritan") or
        std.mem.eql(u8, name, "Script=Samr") or
        std.mem.eql(u8, name, "sc=Samaritan") or
        std.mem.eql(u8, name, "sc=Samr"))
    {
        return (code_point >= 0x000800 and code_point <= 0x00082d) or
            (code_point >= 0x000830 and code_point <= 0x00083e);
    }
    if (std.mem.eql(u8, name, "Script=SignWriting") or
        std.mem.eql(u8, name, "Script=Sgnw") or
        std.mem.eql(u8, name, "sc=SignWriting") or
        std.mem.eql(u8, name, "sc=Sgnw"))
    {
        return (code_point >= 0x01d800 and code_point <= 0x01da8b) or
            (code_point >= 0x01da9b and code_point <= 0x01da9f) or
            (code_point >= 0x01daa1 and code_point <= 0x01daaf);
    }
    if (isSignWritingScriptExtensionsName(name)) return isUnicodeSignWritingScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Siddham") or
        std.mem.eql(u8, name, "Script=Sidd") or
        std.mem.eql(u8, name, "sc=Siddham") or
        std.mem.eql(u8, name, "sc=Sidd"))
    {
        return (code_point >= 0x011580 and code_point <= 0x0115b5) or
            (code_point >= 0x0115b8 and code_point <= 0x0115dd);
    }
    if (std.mem.eql(u8, name, "Script=Sidetic") or
        std.mem.eql(u8, name, "Script=Sidt") or
        std.mem.eql(u8, name, "sc=Sidetic") or
        std.mem.eql(u8, name, "sc=Sidt"))
    {
        return code_point >= 0x010940 and code_point <= 0x010959;
    }
    if (std.mem.eql(u8, name, "Script=Sinhala") or
        std.mem.eql(u8, name, "Script=Sinh") or
        std.mem.eql(u8, name, "sc=Sinhala") or
        std.mem.eql(u8, name, "sc=Sinh"))
    {
        return code_point == 0x000dbd or
            code_point == 0x000dca or
            code_point == 0x000dd6 or
            (code_point >= 0x000d81 and code_point <= 0x000d83) or
            (code_point >= 0x000d85 and code_point <= 0x000d96) or
            (code_point >= 0x000d9a and code_point <= 0x000db1) or
            (code_point >= 0x000db3 and code_point <= 0x000dbb) or
            (code_point >= 0x000dc0 and code_point <= 0x000dc6) or
            (code_point >= 0x000dcf and code_point <= 0x000dd4) or
            (code_point >= 0x000dd8 and code_point <= 0x000ddf) or
            (code_point >= 0x000de6 and code_point <= 0x000def) or
            (code_point >= 0x000df2 and code_point <= 0x000df4) or
            (code_point >= 0x0111e1 and code_point <= 0x0111f4);
    }
    if (std.mem.eql(u8, name, "Script=Sogdian") or
        std.mem.eql(u8, name, "Script=Sogd") or
        std.mem.eql(u8, name, "sc=Sogdian") or
        std.mem.eql(u8, name, "sc=Sogd"))
    {
        return code_point >= 0x010f30 and code_point <= 0x010f59;
    }
    if (std.mem.eql(u8, name, "Script_Extensions=Sogdian") or
        std.mem.eql(u8, name, "Script_Extensions=Sogd") or
        std.mem.eql(u8, name, "scx=Sogdian") or
        std.mem.eql(u8, name, "scx=Sogd"))
    {
        return code_point == 0x000640 or
            (code_point >= 0x010f30 and code_point <= 0x010f59);
    }
    if (std.mem.eql(u8, name, "Script=Soyombo") or
        std.mem.eql(u8, name, "Script=Soyo") or
        std.mem.eql(u8, name, "sc=Soyombo") or
        std.mem.eql(u8, name, "sc=Soyo"))
    {
        return code_point >= 0x011a50 and code_point <= 0x011aa2;
    }
    if (std.mem.eql(u8, name, "Script=Sora_Sompeng") or
        std.mem.eql(u8, name, "Script=Sora") or
        std.mem.eql(u8, name, "sc=Sora_Sompeng") or
        std.mem.eql(u8, name, "sc=Sora"))
    {
        return (code_point >= 0x0110d0 and code_point <= 0x0110e8) or
            (code_point >= 0x0110f0 and code_point <= 0x0110f9);
    }
    if (std.mem.eql(u8, name, "Script=Sundanese") or
        std.mem.eql(u8, name, "Script=Sund") or
        std.mem.eql(u8, name, "sc=Sundanese") or
        std.mem.eql(u8, name, "sc=Sund"))
    {
        return (code_point >= 0x001b80 and code_point <= 0x001bbf) or
            (code_point >= 0x001cc0 and code_point <= 0x001cc7);
    }
    if (std.mem.eql(u8, name, "Script=Sunuwar") or
        std.mem.eql(u8, name, "Script=Sunu") or
        std.mem.eql(u8, name, "sc=Sunuwar") or
        std.mem.eql(u8, name, "sc=Sunu"))
    {
        return (code_point >= 0x011bc0 and code_point <= 0x011be1) or
            (code_point >= 0x011bf0 and code_point <= 0x011bf9);
    }
    if (std.mem.eql(u8, name, "Script=Syloti_Nagri") or
        std.mem.eql(u8, name, "Script=Sylo") or
        std.mem.eql(u8, name, "sc=Syloti_Nagri") or
        std.mem.eql(u8, name, "sc=Sylo"))
    {
        return code_point >= 0x00a800 and code_point <= 0x00a82c;
    }
    if (std.mem.eql(u8, name, "Script=Syriac") or
        std.mem.eql(u8, name, "Script=Syrc") or
        std.mem.eql(u8, name, "sc=Syriac") or
        std.mem.eql(u8, name, "sc=Syrc"))
    {
        return (code_point >= 0x000700 and code_point <= 0x00070d) or
            (code_point >= 0x00070f and code_point <= 0x00074a) or
            (code_point >= 0x00074d and code_point <= 0x00074f) or
            (code_point >= 0x000860 and code_point <= 0x00086a);
    }
    if (std.mem.eql(u8, name, "Script=Tagbanwa") or
        std.mem.eql(u8, name, "Script=Tagb") or
        std.mem.eql(u8, name, "sc=Tagbanwa") or
        std.mem.eql(u8, name, "sc=Tagb"))
    {
        return (code_point >= 0x001760 and code_point <= 0x00176c) or
            (code_point >= 0x00176e and code_point <= 0x001770) or
            (code_point >= 0x001772 and code_point <= 0x001773);
    }
    if (std.mem.eql(u8, name, "Script=Tagalog") or
        std.mem.eql(u8, name, "Script=Tglg") or
        std.mem.eql(u8, name, "sc=Tagalog") or
        std.mem.eql(u8, name, "sc=Tglg"))
    {
        return code_point == 0x00171f or
            (code_point >= 0x001700 and code_point <= 0x001715);
    }
    if (std.mem.eql(u8, name, "Script=Tai_Le") or
        std.mem.eql(u8, name, "Script=Tale") or
        std.mem.eql(u8, name, "sc=Tai_Le") or
        std.mem.eql(u8, name, "sc=Tale"))
    {
        return (code_point >= 0x001950 and code_point <= 0x00196d) or
            (code_point >= 0x001970 and code_point <= 0x001974);
    }
    if (std.mem.eql(u8, name, "Script=Tai_Tham") or
        std.mem.eql(u8, name, "Script=Lana") or
        std.mem.eql(u8, name, "sc=Tai_Tham") or
        std.mem.eql(u8, name, "sc=Lana"))
    {
        return (code_point >= 0x001a20 and code_point <= 0x001a5e) or
            (code_point >= 0x001a60 and code_point <= 0x001a7c) or
            (code_point >= 0x001a7f and code_point <= 0x001a89) or
            (code_point >= 0x001a90 and code_point <= 0x001a99) or
            (code_point >= 0x001aa0 and code_point <= 0x001aad);
    }
    if (isTaiThamScriptExtensionsName(name)) return isUnicodeTaiThamScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Tai_Viet") or
        std.mem.eql(u8, name, "Script=Tavt") or
        std.mem.eql(u8, name, "sc=Tai_Viet") or
        std.mem.eql(u8, name, "sc=Tavt"))
    {
        return (code_point >= 0x00aa80 and code_point <= 0x00aac2) or
            (code_point >= 0x00aadb and code_point <= 0x00aadf);
    }
    if (isTaiVietScriptExtensionsName(name)) return isUnicodeTaiVietScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Tai_Yo") or
        std.mem.eql(u8, name, "Script=Tayo") or
        std.mem.eql(u8, name, "sc=Tai_Yo") or
        std.mem.eql(u8, name, "sc=Tayo"))
    {
        return (code_point >= 0x01e6c0 and code_point <= 0x01e6de) or
            (code_point >= 0x01e6e0 and code_point <= 0x01e6f5) or
            (code_point >= 0x01e6fe and code_point <= 0x01e6ff);
    }
    if (isTaiYoScriptExtensionsName(name)) return isUnicodeTaiYoScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Takri") or
        std.mem.eql(u8, name, "Script=Takr") or
        std.mem.eql(u8, name, "sc=Takri") or
        std.mem.eql(u8, name, "sc=Takr"))
    {
        return (code_point >= 0x011680 and code_point <= 0x0116b9) or
            (code_point >= 0x0116c0 and code_point <= 0x0116c9);
    }
    if (std.mem.eql(u8, name, "Script=Tangsa") or
        std.mem.eql(u8, name, "Script=Tnsa") or
        std.mem.eql(u8, name, "sc=Tangsa") or
        std.mem.eql(u8, name, "sc=Tnsa"))
    {
        return (code_point >= 0x016a70 and code_point <= 0x016abe) or
            (code_point >= 0x016ac0 and code_point <= 0x016ac9);
    }
    if (std.mem.eql(u8, name, "Script=Tamil") or
        std.mem.eql(u8, name, "Script=Taml") or
        std.mem.eql(u8, name, "sc=Tamil") or
        std.mem.eql(u8, name, "sc=Taml"))
    {
        return code_point == 0x000b9c or
            code_point == 0x000bd0 or
            code_point == 0x000bd7 or
            code_point == 0x011fff or
            (code_point >= 0x000b82 and code_point <= 0x000b83) or
            (code_point >= 0x000b85 and code_point <= 0x000b8a) or
            (code_point >= 0x000b8e and code_point <= 0x000b90) or
            (code_point >= 0x000b92 and code_point <= 0x000b95) or
            (code_point >= 0x000b99 and code_point <= 0x000b9a) or
            (code_point >= 0x000b9e and code_point <= 0x000b9f) or
            (code_point >= 0x000ba3 and code_point <= 0x000ba4) or
            (code_point >= 0x000ba8 and code_point <= 0x000baa) or
            (code_point >= 0x000bae and code_point <= 0x000bb9) or
            (code_point >= 0x000bbe and code_point <= 0x000bc2) or
            (code_point >= 0x000bc6 and code_point <= 0x000bc8) or
            (code_point >= 0x000bca and code_point <= 0x000bcd) or
            (code_point >= 0x000be6 and code_point <= 0x000bfa) or
            (code_point >= 0x011fc0 and code_point <= 0x011ff1);
    }
    if (isTamilScriptExtensionsName(name)) return isUnicodeTamilScriptExtensionsCodePoint(code_point);
    if (isHanunooScriptExtensionsName(name)) return isUnicodeHanunooScriptExtensionsCodePoint(code_point);
    if (isImperialAramaicScriptExtensionsName(name)) return isUnicodeImperialAramaicScriptExtensionsCodePoint(code_point);
    if (isKawiScriptExtensionsName(name)) return isUnicodeKawiScriptExtensionsCodePoint(code_point);
    if (isKayahLiScriptExtensionsName(name)) return isUnicodeKayahLiScriptExtensionsCodePoint(code_point);
    if (isLaoScriptExtensionsName(name)) return isUnicodeLaoScriptExtensionsCodePoint(code_point);
    if (isLycianScriptExtensionsName(name)) return isUnicodeLycianScriptExtensionsCodePoint(code_point);
    if (isMedefaidrinScriptExtensionsName(name)) return isUnicodeMedefaidrinScriptExtensionsCodePoint(code_point);
    if (isMeeteiMayekScriptExtensionsName(name)) return isUnicodeMeeteiMayekScriptExtensionsCodePoint(code_point);
    if (isMendeKikakuiScriptExtensionsName(name)) return isUnicodeMendeKikakuiScriptExtensionsCodePoint(code_point);
    if (isMeroiticCursiveScriptExtensionsName(name)) return isUnicodeMeroiticCursiveScriptExtensionsCodePoint(code_point);
    if (isMeroiticHieroglyphsScriptExtensionsName(name)) return isUnicodeMeroiticHieroglyphsScriptExtensionsCodePoint(code_point);
    if (isMroScriptExtensionsName(name)) return isUnicodeMroScriptExtensionsCodePoint(code_point);
    if (isNabataeanScriptExtensionsName(name)) return isUnicodeNabataeanScriptExtensionsCodePoint(code_point);
    if (isNushuScriptExtensionsName(name)) return isUnicodeNushuScriptExtensionsCodePoint(code_point);
    if (isLinearAScriptExtensionsName(name)) return isUnicodeLinearAScriptExtensionsCodePoint(code_point);
    if (isLinearBScriptExtensionsName(name)) return isUnicodeLinearBScriptExtensionsCodePoint(code_point);
    if (isLisuScriptExtensionsName(name)) return isUnicodeLisuScriptExtensionsCodePoint(code_point);
    if (isLydianScriptExtensionsName(name)) return isUnicodeLydianScriptExtensionsCodePoint(code_point);
    if (isMahajaniScriptExtensionsName(name)) return isUnicodeMahajaniScriptExtensionsCodePoint(code_point);
    if (isManichaeanScriptExtensionsName(name)) return isUnicodeManichaeanScriptExtensionsCodePoint(code_point);
    if (isMasaramGondiScriptExtensionsName(name)) return isUnicodeMasaramGondiScriptExtensionsCodePoint(code_point);
    if (isMultaniScriptExtensionsName(name)) return isUnicodeMultaniScriptExtensionsCodePoint(code_point);
    if (std.mem.eql(u8, name, "Script=Telugu") or
        std.mem.eql(u8, name, "Script=Telu") or
        std.mem.eql(u8, name, "sc=Telugu") or
        std.mem.eql(u8, name, "sc=Telu"))
    {
        return (code_point >= 0x000c00 and code_point <= 0x000c0c) or
            (code_point >= 0x000c0e and code_point <= 0x000c10) or
            (code_point >= 0x000c12 and code_point <= 0x000c28) or
            (code_point >= 0x000c2a and code_point <= 0x000c39) or
            (code_point >= 0x000c3c and code_point <= 0x000c44) or
            (code_point >= 0x000c46 and code_point <= 0x000c48) or
            (code_point >= 0x000c4a and code_point <= 0x000c4d) or
            (code_point >= 0x000c55 and code_point <= 0x000c56) or
            (code_point >= 0x000c58 and code_point <= 0x000c5a) or
            (code_point >= 0x000c5c and code_point <= 0x000c5d) or
            (code_point >= 0x000c60 and code_point <= 0x000c63) or
            (code_point >= 0x000c66 and code_point <= 0x000c6f) or
            (code_point >= 0x000c77 and code_point <= 0x000c7f);
    }
    if (std.mem.eql(u8, name, "Script=Tangut") or
        std.mem.eql(u8, name, "Script=Tang") or
        std.mem.eql(u8, name, "sc=Tangut") or
        std.mem.eql(u8, name, "sc=Tang"))
    {
        return code_point == 0x016fe0 or
            (code_point >= 0x017000 and code_point <= 0x018aff) or
            (code_point >= 0x018d00 and code_point <= 0x018d1e) or
            (code_point >= 0x018d80 and code_point <= 0x018df2);
    }
    if (std.mem.eql(u8, name, "Script=Thai") or std.mem.eql(u8, name, "sc=Thai")) {
        return (code_point >= 0x000e01 and code_point <= 0x000e3a) or
            (code_point >= 0x000e40 and code_point <= 0x000e5b);
    }
    if (std.mem.eql(u8, name, "Script=Thaana") or
        std.mem.eql(u8, name, "Script=Thaa") or
        std.mem.eql(u8, name, "sc=Thaana") or
        std.mem.eql(u8, name, "sc=Thaa"))
    {
        return code_point >= 0x000780 and code_point <= 0x0007b1;
    }
    if (std.mem.eql(u8, name, "Script=Tibetan") or
        std.mem.eql(u8, name, "Script=Tibt") or
        std.mem.eql(u8, name, "sc=Tibetan") or
        std.mem.eql(u8, name, "sc=Tibt"))
    {
        return (code_point >= 0x000f00 and code_point <= 0x000f47) or
            (code_point >= 0x000f49 and code_point <= 0x000f6c) or
            (code_point >= 0x000f71 and code_point <= 0x000f97) or
            (code_point >= 0x000f99 and code_point <= 0x000fbc) or
            (code_point >= 0x000fbe and code_point <= 0x000fcc) or
            (code_point >= 0x000fce and code_point <= 0x000fd4) or
            (code_point >= 0x000fd9 and code_point <= 0x000fda);
    }
    if (std.mem.eql(u8, name, "Script=Tifinagh") or
        std.mem.eql(u8, name, "Script=Tfng") or
        std.mem.eql(u8, name, "sc=Tifinagh") or
        std.mem.eql(u8, name, "sc=Tfng"))
    {
        return code_point == 0x002d7f or
            (code_point >= 0x002d30 and code_point <= 0x002d67) or
            (code_point >= 0x002d6f and code_point <= 0x002d70);
    }
    if (std.mem.eql(u8, name, "Script=Tirhuta") or
        std.mem.eql(u8, name, "Script=Tirh") or
        std.mem.eql(u8, name, "sc=Tirhuta") or
        std.mem.eql(u8, name, "sc=Tirh"))
    {
        return (code_point >= 0x011480 and code_point <= 0x0114c7) or
            (code_point >= 0x0114d0 and code_point <= 0x0114d9);
    }
    if (std.mem.eql(u8, name, "Script=Todhri") or
        std.mem.eql(u8, name, "Script=Todr") or
        std.mem.eql(u8, name, "sc=Todhri") or
        std.mem.eql(u8, name, "sc=Todr"))
    {
        return code_point >= 0x0105c0 and code_point <= 0x0105f3;
    }
    if (std.mem.eql(u8, name, "Script=Tolong_Siki") or
        std.mem.eql(u8, name, "Script=Tols") or
        std.mem.eql(u8, name, "sc=Tolong_Siki") or
        std.mem.eql(u8, name, "sc=Tols"))
    {
        return (code_point >= 0x011db0 and code_point <= 0x011ddb) or
            (code_point >= 0x011de0 and code_point <= 0x011de9);
    }
    if (std.mem.eql(u8, name, "Script=Toto") or std.mem.eql(u8, name, "sc=Toto")) {
        return code_point >= 0x01e290 and code_point <= 0x01e2ae;
    }
    if (std.mem.eql(u8, name, "Script=Tulu_Tigalari") or
        std.mem.eql(u8, name, "Script=Tutg") or
        std.mem.eql(u8, name, "sc=Tulu_Tigalari") or
        std.mem.eql(u8, name, "sc=Tutg"))
    {
        return code_point == 0x01138b or
            code_point == 0x01138e or
            code_point == 0x0113c2 or
            code_point == 0x0113c5 or
            (code_point >= 0x011380 and code_point <= 0x011389) or
            (code_point >= 0x011390 and code_point <= 0x0113b5) or
            (code_point >= 0x0113b7 and code_point <= 0x0113c0) or
            (code_point >= 0x0113c7 and code_point <= 0x0113ca) or
            (code_point >= 0x0113cc and code_point <= 0x0113d5) or
            (code_point >= 0x0113d7 and code_point <= 0x0113d8) or
            (code_point >= 0x0113e1 and code_point <= 0x0113e2);
    }
    if (std.mem.eql(u8, name, "Script=Ugaritic") or
        std.mem.eql(u8, name, "Script=Ugar") or
        std.mem.eql(u8, name, "sc=Ugaritic") or
        std.mem.eql(u8, name, "sc=Ugar"))
    {
        return code_point == 0x01039f or
            (code_point >= 0x010380 and code_point <= 0x01039d);
    }
    if (std.mem.eql(u8, name, "Script=Vai") or
        std.mem.eql(u8, name, "Script=Vaii") or
        std.mem.eql(u8, name, "sc=Vai") or
        std.mem.eql(u8, name, "sc=Vaii"))
    {
        return code_point >= 0x00a500 and code_point <= 0x00a62b;
    }
    if (std.mem.eql(u8, name, "Script=Vithkuqi") or
        std.mem.eql(u8, name, "Script=Vith") or
        std.mem.eql(u8, name, "sc=Vithkuqi") or
        std.mem.eql(u8, name, "sc=Vith"))
    {
        return (code_point >= 0x010570 and code_point <= 0x01057a) or
            (code_point >= 0x01057c and code_point <= 0x01058a) or
            (code_point >= 0x01058c and code_point <= 0x010592) or
            (code_point >= 0x010594 and code_point <= 0x010595) or
            (code_point >= 0x010597 and code_point <= 0x0105a1) or
            (code_point >= 0x0105a3 and code_point <= 0x0105b1) or
            (code_point >= 0x0105b3 and code_point <= 0x0105b9) or
            (code_point >= 0x0105bb and code_point <= 0x0105bc);
    }
    if (std.mem.eql(u8, name, "Script=Wancho") or
        std.mem.eql(u8, name, "Script=Wcho") or
        std.mem.eql(u8, name, "sc=Wancho") or
        std.mem.eql(u8, name, "sc=Wcho"))
    {
        return code_point == 0x01e2ff or
            (code_point >= 0x01e2c0 and code_point <= 0x01e2f9);
    }
    if (std.mem.eql(u8, name, "Script=Warang_Citi") or
        std.mem.eql(u8, name, "Script=Wara") or
        std.mem.eql(u8, name, "sc=Warang_Citi") or
        std.mem.eql(u8, name, "sc=Wara"))
    {
        return code_point == 0x0118ff or
            (code_point >= 0x0118a0 and code_point <= 0x0118f2);
    }
    if (std.mem.eql(u8, name, "Script=Yezidi") or
        std.mem.eql(u8, name, "Script=Yezi") or
        std.mem.eql(u8, name, "sc=Yezidi") or
        std.mem.eql(u8, name, "sc=Yezi"))
    {
        return (code_point >= 0x010e80 and code_point <= 0x010ea9) or
            (code_point >= 0x010eab and code_point <= 0x010ead) or
            (code_point >= 0x010eb0 and code_point <= 0x010eb1);
    }
    if (std.mem.eql(u8, name, "Script=Yi") or
        std.mem.eql(u8, name, "Script=Yiii") or
        std.mem.eql(u8, name, "sc=Yi") or
        std.mem.eql(u8, name, "sc=Yiii"))
    {
        return (code_point >= 0x00a000 and code_point <= 0x00a48c) or
            (code_point >= 0x00a490 and code_point <= 0x00a4c6);
    }
    if (std.mem.eql(u8, name, "Script=Zanabazar_Square") or
        std.mem.eql(u8, name, "Script=Zanb") or
        std.mem.eql(u8, name, "sc=Zanabazar_Square") or
        std.mem.eql(u8, name, "sc=Zanb"))
    {
        return code_point >= 0x011a00 and code_point <= 0x011a47;
    }
    if (std.mem.eql(u8, name, "Any")) return code_point <= 0x10ffff;
    if (std.mem.eql(u8, name, "Assigned")) return isUnicodeAssignedCodePoint(code_point);
    if (std.mem.eql(u8, name, "Emoji")) return unicode_tables.isEmojiCodePoint(code_point);
    if (std.mem.eql(u8, name, "Emoji_Component") or std.mem.eql(u8, name, "EComp")) return unicode_tables.isEmojiComponentCodePoint(code_point);
    if (std.mem.eql(u8, name, "Emoji_Modifier") or std.mem.eql(u8, name, "EMod")) return code_point >= 0x01f3fb and code_point <= 0x01f3ff;
    if (std.mem.eql(u8, name, "Emoji_Modifier_Base") or std.mem.eql(u8, name, "EBase")) return unicode_tables.isEmojiModifierBaseCodePoint(code_point);
    if (std.mem.eql(u8, name, "Emoji_Presentation") or std.mem.eql(u8, name, "EPres")) return unicode_tables.isEmojiPresentationCodePoint(code_point);
    if (std.mem.eql(u8, name, "Extended_Pictographic") or std.mem.eql(u8, name, "ExtPict")) return isUnicodeExtendedPictographicCodePoint(code_point);
    if (std.mem.eql(u8, name, "Grapheme_Extend") or std.mem.eql(u8, name, "Gr_Ext")) return isUnicodeGraphemeExtendCodePoint(code_point);
    if (std.mem.eql(u8, name, "Extender") or std.mem.eql(u8, name, "Ext")) return isUnicodeExtenderCodePoint(code_point);
    if (std.mem.eql(u8, name, "Sentence_Terminal") or std.mem.eql(u8, name, "STerm")) {
        const singles = [_]u21{
            0x000021, 0x00002e, 0x00003f, 0x000589, 0x0006d4, 0x0007f9,
            0x000837, 0x000839, 0x001362, 0x00166e, 0x001803, 0x001809,
            0x002024, 0x002e2e, 0x002e3c, 0x003002, 0x00a4ff, 0x00a6f3,
            0x00a6f7, 0x00a92f, 0x00abeb, 0x00fe12, 0x00fe52, 0x00ff01,
            0x00ff0e, 0x00ff1f, 0x00ff61, 0x0111cd, 0x0112a9, 0x011944,
            0x011946, 0x016af5, 0x016b44, 0x016e98, 0x01bc9f, 0x01da88,
        };
        const ranges = [_][2]u21{
            .{ 0x00061d, 0x00061f },
            .{ 0x000700, 0x000702 },
            .{ 0x00083d, 0x00083e },
            .{ 0x000964, 0x000965 },
            .{ 0x00104a, 0x00104b },
            .{ 0x001367, 0x001368 },
            .{ 0x001735, 0x001736 },
            .{ 0x0017d4, 0x0017d5 },
            .{ 0x001944, 0x001945 },
            .{ 0x001aa8, 0x001aab },
            .{ 0x001b4e, 0x001b4f },
            .{ 0x001b5a, 0x001b5b },
            .{ 0x001b5e, 0x001b5f },
            .{ 0x001b7d, 0x001b7f },
            .{ 0x001c3b, 0x001c3c },
            .{ 0x001c7e, 0x001c7f },
            .{ 0x00203c, 0x00203d },
            .{ 0x002047, 0x002049 },
            .{ 0x002cf9, 0x002cfb },
            .{ 0x002e53, 0x002e54 },
            .{ 0x00a60e, 0x00a60f },
            .{ 0x00a876, 0x00a877 },
            .{ 0x00a8ce, 0x00a8cf },
            .{ 0x00a9c8, 0x00a9c9 },
            .{ 0x00aa5d, 0x00aa5f },
            .{ 0x00aaf0, 0x00aaf1 },
            .{ 0x00fe15, 0x00fe16 },
            .{ 0x00fe56, 0x00fe57 },
            .{ 0x010a56, 0x010a57 },
            .{ 0x010f55, 0x010f59 },
            .{ 0x010f86, 0x010f89 },
            .{ 0x011047, 0x011048 },
            .{ 0x0110be, 0x0110c1 },
            .{ 0x011141, 0x011143 },
            .{ 0x0111c5, 0x0111c6 },
            .{ 0x0111de, 0x0111df },
            .{ 0x011238, 0x011239 },
            .{ 0x01123b, 0x01123c },
            .{ 0x0113d4, 0x0113d5 },
            .{ 0x01144b, 0x01144c },
            .{ 0x0115c2, 0x0115c3 },
            .{ 0x0115c9, 0x0115d7 },
            .{ 0x011641, 0x011642 },
            .{ 0x01173c, 0x01173e },
            .{ 0x011a42, 0x011a43 },
            .{ 0x011a9b, 0x011a9c },
            .{ 0x011c41, 0x011c42 },
            .{ 0x011ef7, 0x011ef8 },
            .{ 0x011f43, 0x011f44 },
            .{ 0x016a6e, 0x016a6f },
            .{ 0x016b37, 0x016b38 },
            .{ 0x016d6e, 0x016d6f },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Soft_Dotted") or std.mem.eql(u8, name, "SD")) {
        const singles = [_]u21{
            0x00012f, 0x000249, 0x000268, 0x00029d, 0x0002b2, 0x0003f3,
            0x000456, 0x000458, 0x001d62, 0x001d96, 0x001da4, 0x001da8,
            0x001e2d, 0x001ecb, 0x002071, 0x002c7c, 0x01df1a, 0x01e068,
        };
        const ranges = [_][2]u21{
            .{ 0x000069, 0x00006a },
            .{ 0x002148, 0x002149 },
            .{ 0x01d422, 0x01d423 },
            .{ 0x01d456, 0x01d457 },
            .{ 0x01d48a, 0x01d48b },
            .{ 0x01d4be, 0x01d4bf },
            .{ 0x01d4f2, 0x01d4f3 },
            .{ 0x01d526, 0x01d527 },
            .{ 0x01d55a, 0x01d55b },
            .{ 0x01d58e, 0x01d58f },
            .{ 0x01d5c2, 0x01d5c3 },
            .{ 0x01d5f6, 0x01d5f7 },
            .{ 0x01d62a, 0x01d62b },
            .{ 0x01d65e, 0x01d65f },
            .{ 0x01d692, 0x01d693 },
            .{ 0x01e04c, 0x01e04d },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Terminal_Punctuation") or std.mem.eql(u8, name, "Term")) {
        const singles = [_]u21{
            0x000021, 0x00002c, 0x00002e, 0x00003f, 0x00037e, 0x000387,
            0x000589, 0x0005c3, 0x00060c, 0x00061b, 0x0006d4, 0x00070c,
            0x00085e, 0x000f08, 0x00166e, 0x0017da, 0x002024, 0x002e2e,
            0x002e3c, 0x002e41, 0x002e4c, 0x00a92f, 0x00aadf, 0x00abeb,
            0x00fe12, 0x00ff01, 0x00ff0c, 0x00ff0e, 0x00ff1f, 0x00ff61,
            0x00ff64, 0x01039f, 0x0103d0, 0x010857, 0x01091f, 0x0111cd,
            0x0112a9, 0x011944, 0x011946, 0x011c71, 0x016af5, 0x016b44,
            0x01bc9f,
        };
        const ranges = [_][2]u21{
            .{ 0x00003a, 0x00003b },
            .{ 0x00061d, 0x00061f },
            .{ 0x000700, 0x00070a },
            .{ 0x0007f8, 0x0007f9 },
            .{ 0x000830, 0x000835 },
            .{ 0x000837, 0x00083e },
            .{ 0x000964, 0x000965 },
            .{ 0x000e5a, 0x000e5b },
            .{ 0x000f0d, 0x000f12 },
            .{ 0x00104a, 0x00104b },
            .{ 0x001361, 0x001368 },
            .{ 0x0016eb, 0x0016ed },
            .{ 0x001735, 0x001736 },
            .{ 0x0017d4, 0x0017d6 },
            .{ 0x001802, 0x001805 },
            .{ 0x001808, 0x001809 },
            .{ 0x001944, 0x001945 },
            .{ 0x001aa8, 0x001aab },
            .{ 0x001b4e, 0x001b4f },
            .{ 0x001b5a, 0x001b5b },
            .{ 0x001b5d, 0x001b5f },
            .{ 0x001b7d, 0x001b7f },
            .{ 0x001c3b, 0x001c3f },
            .{ 0x001c7e, 0x001c7f },
            .{ 0x00203c, 0x00203d },
            .{ 0x002047, 0x002049 },
            .{ 0x002cf9, 0x002cfb },
            .{ 0x002e4e, 0x002e4f },
            .{ 0x002e53, 0x002e54 },
            .{ 0x003001, 0x003002 },
            .{ 0x00a4fe, 0x00a4ff },
            .{ 0x00a60d, 0x00a60f },
            .{ 0x00a6f3, 0x00a6f7 },
            .{ 0x00a876, 0x00a877 },
            .{ 0x00a8ce, 0x00a8cf },
            .{ 0x00a9c7, 0x00a9c9 },
            .{ 0x00aa5d, 0x00aa5f },
            .{ 0x00aaf0, 0x00aaf1 },
            .{ 0x00fe15, 0x00fe16 },
            .{ 0x00fe50, 0x00fe52 },
            .{ 0x00fe54, 0x00fe57 },
            .{ 0x00ff1a, 0x00ff1b },
            .{ 0x010a56, 0x010a57 },
            .{ 0x010af0, 0x010af5 },
            .{ 0x010b3a, 0x010b3f },
            .{ 0x010b99, 0x010b9c },
            .{ 0x010f55, 0x010f59 },
            .{ 0x010f86, 0x010f89 },
            .{ 0x011047, 0x01104d },
            .{ 0x0110be, 0x0110c1 },
            .{ 0x011141, 0x011143 },
            .{ 0x0111c5, 0x0111c6 },
            .{ 0x0111de, 0x0111df },
            .{ 0x011238, 0x01123c },
            .{ 0x0113d4, 0x0113d5 },
            .{ 0x01144b, 0x01144d },
            .{ 0x01145a, 0x01145b },
            .{ 0x0115c2, 0x0115c5 },
            .{ 0x0115c9, 0x0115d7 },
            .{ 0x011641, 0x011642 },
            .{ 0x01173c, 0x01173e },
            .{ 0x011a42, 0x011a43 },
            .{ 0x011a9b, 0x011a9c },
            .{ 0x011aa1, 0x011aa2 },
            .{ 0x011c41, 0x011c43 },
            .{ 0x011ef7, 0x011ef8 },
            .{ 0x011f43, 0x011f44 },
            .{ 0x012470, 0x012474 },
            .{ 0x016a6e, 0x016a6f },
            .{ 0x016b37, 0x016b39 },
            .{ 0x016d6e, 0x016d6f },
            .{ 0x016e97, 0x016e98 },
            .{ 0x01da87, 0x01da8a },
        };
        return codePointInUnicodeSet(code_point, &singles, &ranges);
    }
    if (std.mem.eql(u8, name, "Math")) return isUnicodeMathCodePoint(code_point);
    if (std.mem.eql(u8, name, "Ideographic") or std.mem.eql(u8, name, "Ideo")) return isUnicodeIdeographicCodePoint(code_point);
    if (std.mem.eql(u8, name, "Unified_Ideograph") or std.mem.eql(u8, name, "UIdeo")) return isUnicodeUnifiedIdeographCodePoint(code_point);
    if (std.mem.eql(u8, name, "Grapheme_Base") or std.mem.eql(u8, name, "Gr_Base")) return isUnicodeGraphemeBaseCodePoint(code_point);
    return false;
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

pub fn codePointInUnicodeSet(code_point: u21, singles: []const u21, ranges: []const [2]u21) bool {
    for (singles) |single| {
        if (code_point == single) return true;
    }
    for (ranges) |range| {
        if (code_point >= range[0] and code_point <= range[1]) return true;
    }
    return false;
}

pub fn codePointInSortedUnicodeRanges(code_point: u21, ranges: []const [2]u21) bool {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = ranges[mid];
        if (code_point < range[0]) {
            high = mid;
        } else if (code_point > range[1]) {
            low = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

pub fn codePointInSortedUnicodeSingles(code_point: u21, singles: []const u21) bool {
    var low: usize = 0;
    var high: usize = singles.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const single = singles[mid];
        if (code_point < single) {
            high = mid;
        } else if (code_point > single) {
            low = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

pub fn isUnicodeAdlamScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00061f or
        code_point == 0x000640 or
        code_point == 0x00204f or
        code_point == 0x002e41 or
        (code_point >= 0x01e900 and code_point <= 0x01e94b) or
        (code_point >= 0x01e950 and code_point <= 0x01e959) or
        (code_point >= 0x01e95e and code_point <= 0x01e95f);
}

pub fn isUnicodeArabicScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00204f or
        code_point == 0x002e41 or
        code_point == 0x01ee24 or
        code_point == 0x01ee27 or
        code_point == 0x01ee39 or
        code_point == 0x01ee3b or
        code_point == 0x01ee42 or
        code_point == 0x01ee47 or
        code_point == 0x01ee49 or
        code_point == 0x01ee4b or
        code_point == 0x01ee54 or
        code_point == 0x01ee57 or
        code_point == 0x01ee59 or
        code_point == 0x01ee5b or
        code_point == 0x01ee5d or
        code_point == 0x01ee5f or
        code_point == 0x01ee64 or
        code_point == 0x01ee7e or
        (code_point >= 0x000600 and code_point <= 0x000604) or
        (code_point >= 0x000606 and code_point <= 0x0006dc) or
        (code_point >= 0x0006de and code_point <= 0x0006ff) or
        (code_point >= 0x000750 and code_point <= 0x00077f) or
        (code_point >= 0x000870 and code_point <= 0x000891) or
        (code_point >= 0x000897 and code_point <= 0x0008e1) or
        (code_point >= 0x0008e3 and code_point <= 0x0008ff) or
        (code_point >= 0x00fb50 and code_point <= 0x00fdcf) or
        (code_point >= 0x00fdf0 and code_point <= 0x00fdff) or
        (code_point >= 0x00fe70 and code_point <= 0x00fe74) or
        (code_point >= 0x00fe76 and code_point <= 0x00fefc) or
        (code_point >= 0x0102e0 and code_point <= 0x0102fb) or
        (code_point >= 0x010e60 and code_point <= 0x010e7e) or
        (code_point >= 0x010ec2 and code_point <= 0x010ec7) or
        (code_point >= 0x010ed0 and code_point <= 0x010ed8) or
        (code_point >= 0x010efa and code_point <= 0x010eff) or
        (code_point >= 0x01ee00 and code_point <= 0x01ee03) or
        (code_point >= 0x01ee05 and code_point <= 0x01ee1f) or
        (code_point >= 0x01ee21 and code_point <= 0x01ee22) or
        (code_point >= 0x01ee29 and code_point <= 0x01ee32) or
        (code_point >= 0x01ee34 and code_point <= 0x01ee37) or
        (code_point >= 0x01ee4d and code_point <= 0x01ee4f) or
        (code_point >= 0x01ee51 and code_point <= 0x01ee52) or
        (code_point >= 0x01ee61 and code_point <= 0x01ee62) or
        (code_point >= 0x01ee67 and code_point <= 0x01ee6a) or
        (code_point >= 0x01ee6c and code_point <= 0x01ee72) or
        (code_point >= 0x01ee74 and code_point <= 0x01ee77) or
        (code_point >= 0x01ee79 and code_point <= 0x01ee7c) or
        (code_point >= 0x01ee80 and code_point <= 0x01ee89) or
        (code_point >= 0x01ee8b and code_point <= 0x01ee9b) or
        (code_point >= 0x01eea1 and code_point <= 0x01eea3) or
        (code_point >= 0x01eea5 and code_point <= 0x01eea9) or
        (code_point >= 0x01eeab and code_point <= 0x01eebb) or
        (code_point >= 0x01eef0 and code_point <= 0x01eef1);
}

pub fn isUnicodeArmenianScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000308 or
        (code_point >= 0x000531 and code_point <= 0x000556) or
        (code_point >= 0x000559 and code_point <= 0x00058a) or
        (code_point >= 0x00058d and code_point <= 0x00058f) or
        (code_point >= 0x00fb13 and code_point <= 0x00fb17);
}

pub fn isUnicodeAvestanScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        (code_point >= 0x002e30 and code_point <= 0x002e31) or
        (code_point >= 0x010b00 and code_point <= 0x010b35) or
        (code_point >= 0x010b39 and code_point <= 0x010b3f);
}

pub fn isUnicodeBengaliScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0002bc or
        code_point == 0x0009b2 or
        code_point == 0x0009d7 or
        code_point == 0x001cd0 or
        code_point == 0x001cd2 or
        code_point == 0x001cd8 or
        code_point == 0x001ce1 or
        code_point == 0x001cea or
        code_point == 0x001ced or
        code_point == 0x001cf2 or
        code_point == 0x00a8f1 or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000980 and code_point <= 0x000983) or
        (code_point >= 0x000985 and code_point <= 0x00098c) or
        (code_point >= 0x00098f and code_point <= 0x000990) or
        (code_point >= 0x000993 and code_point <= 0x0009a8) or
        (code_point >= 0x0009aa and code_point <= 0x0009b0) or
        (code_point >= 0x0009b6 and code_point <= 0x0009b9) or
        (code_point >= 0x0009bc and code_point <= 0x0009c4) or
        (code_point >= 0x0009c7 and code_point <= 0x0009c8) or
        (code_point >= 0x0009cb and code_point <= 0x0009ce) or
        (code_point >= 0x0009dc and code_point <= 0x0009dd) or
        (code_point >= 0x0009df and code_point <= 0x0009e3) or
        (code_point >= 0x0009e6 and code_point <= 0x0009fe) or
        (code_point >= 0x001cd5 and code_point <= 0x001cd6) or
        (code_point >= 0x001cf5 and code_point <= 0x001cf7);
}

pub fn isUnicodeBopomofoScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0002c7 or
        code_point == 0x0002d9 or
        code_point == 0x003030 or
        code_point == 0x003037 or
        code_point == 0x0030fb or
        (code_point >= 0x0002c9 and code_point <= 0x0002cb) or
        (code_point >= 0x0002ea and code_point <= 0x0002eb) or
        (code_point >= 0x003001 and code_point <= 0x003003) or
        (code_point >= 0x003008 and code_point <= 0x003011) or
        (code_point >= 0x003013 and code_point <= 0x00301f) or
        (code_point >= 0x00302a and code_point <= 0x00302d) or
        (code_point >= 0x003105 and code_point <= 0x00312f) or
        (code_point >= 0x0031a0 and code_point <= 0x0031bf) or
        (code_point >= 0x00fe45 and code_point <= 0x00fe46) or
        (code_point >= 0x00ff61 and code_point <= 0x00ff65);
}

pub fn isUnicodeBugineseScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00a9cf or
        (code_point >= 0x001a00 and code_point <= 0x001a1b) or
        (code_point >= 0x001a1e and code_point <= 0x001a1f);
}

pub fn isUnicodeCarianScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x00205a or
        code_point == 0x00205d or
        code_point == 0x002e31 or
        (code_point >= 0x0102a0 and code_point <= 0x0102d0);
}

pub fn isUnicodeCaucasianAlbanianScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000304 or
        code_point == 0x000331 or
        code_point == 0x00035e or
        code_point == 0x01056f or
        (code_point >= 0x010530 and code_point <= 0x010563);
}

pub fn isUnicodeChakmaScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x0009e6 and code_point <= 0x0009ef) or
        (code_point >= 0x001040 and code_point <= 0x001049) or
        (code_point >= 0x011100 and code_point <= 0x011134) or
        (code_point >= 0x011136 and code_point <= 0x011147);
}

pub fn isUnicodeCherokeeScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000304 or
        (code_point >= 0x000300 and code_point <= 0x000302) or
        (code_point >= 0x00030b and code_point <= 0x00030c) or
        (code_point >= 0x000323 and code_point <= 0x000324) or
        (code_point >= 0x000330 and code_point <= 0x000331) or
        (code_point >= 0x0013a0 and code_point <= 0x0013f5) or
        (code_point >= 0x0013f8 and code_point <= 0x0013fd) or
        (code_point >= 0x00ab70 and code_point <= 0x00abbf);
}

pub fn isUnicodeCopticScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x0003e2, 0x0003ef }, .{ 0x002c80, 0x002cf3 }, .{ 0x002cf9, 0x002cff },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeInheritedScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000670, 0x001ced, 0x001cf4, 0x0101fd, 0x0102e0, 0x01133b,
    };
    const ranges = [_][2]u21{
        .{ 0x000300, 0x00036f }, .{ 0x000485, 0x000486 }, .{ 0x00064b, 0x000655 },
        .{ 0x000951, 0x000954 }, .{ 0x001ab0, 0x001add }, .{ 0x001ae0, 0x001aeb },
        .{ 0x001cd0, 0x001cd2 }, .{ 0x001cd4, 0x001ce0 }, .{ 0x001ce2, 0x001ce8 },
        .{ 0x001cf8, 0x001cf9 }, .{ 0x001dc0, 0x001dff }, .{ 0x00200c, 0x00200d },
        .{ 0x0020d0, 0x0020f0 }, .{ 0x00302a, 0x00302d }, .{ 0x003099, 0x00309a },
        .{ 0x00fe00, 0x00fe0f }, .{ 0x00fe20, 0x00fe2d }, .{ 0x01cf00, 0x01cf2d },
        .{ 0x01cf30, 0x01cf46 }, .{ 0x01d167, 0x01d169 }, .{ 0x01d17b, 0x01d182 },
        .{ 0x01d185, 0x01d18b }, .{ 0x01d1aa, 0x01d1ad }, .{ 0x0e0100, 0x0e01ef },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeNewaScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011400, 0x01145b }, .{ 0x01145d, 0x011461 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeNushuScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x016fe1,
    };
    const ranges = [_][2]u21{
        .{ 0x01b170, 0x01b2fb },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOghamScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x001680, 0x00169c },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOlChikiScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x001c50, 0x001c7f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMiaoScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x016f00, 0x016f4a }, .{ 0x016f4f, 0x016f87 }, .{ 0x016f8f, 0x016f9f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeNandinagariScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x0119a0, 0x0119a7 }, .{ 0x0119aa, 0x0119d7 }, .{ 0x0119da, 0x0119e4 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeNkoScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x0007c0, 0x0007fa }, .{ 0x0007fd, 0x0007ff },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeNyiakengPuachueHmongScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x01e100, 0x01e12c }, .{ 0x01e130, 0x01e13d }, .{ 0x01e140, 0x01e149 },
        .{ 0x01e14e, 0x01e14f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOlOnalScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x01e5ff,
    };
    const ranges = [_][2]u21{
        .{ 0x01e5d0, 0x01e5fa },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOlOnalScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x01e5ff or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x01e5d0 and code_point <= 0x01e5fa);
}

pub fn isUnicodeOldHungarianScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010c80, 0x010cb2 }, .{ 0x010cc0, 0x010cf2 }, .{ 0x010cfa, 0x010cff },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOldPermicScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010350, 0x01037a },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOldPersianScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x0103a0, 0x0103c3 }, .{ 0x0103c8, 0x0103d5 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOriyaScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x000b01, 0x000b03 }, .{ 0x000b05, 0x000b0c }, .{ 0x000b0f, 0x000b10 },
        .{ 0x000b13, 0x000b28 }, .{ 0x000b2a, 0x000b30 }, .{ 0x000b32, 0x000b33 },
        .{ 0x000b35, 0x000b39 }, .{ 0x000b3c, 0x000b44 }, .{ 0x000b47, 0x000b48 },
        .{ 0x000b4b, 0x000b4d }, .{ 0x000b55, 0x000b57 }, .{ 0x000b5c, 0x000b5d },
        .{ 0x000b5f, 0x000b63 }, .{ 0x000b66, 0x000b77 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOsageScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x0104b0, 0x0104d3 }, .{ 0x0104d8, 0x0104fb },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOsmanyaScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010480, 0x01049d }, .{ 0x0104a0, 0x0104a9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodePahawhHmongScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x016b00, 0x016b45 }, .{ 0x016b50, 0x016b59 }, .{ 0x016b5b, 0x016b61 },
        .{ 0x016b63, 0x016b77 }, .{ 0x016b7d, 0x016b8f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeKiratRaiScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x016d40, 0x016d79 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOldItalicScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010300, 0x010323 }, .{ 0x01032d, 0x01032f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOldNorthArabianScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010a80, 0x010a9f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOldSogdianScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010f00, 0x010f27 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOldSouthArabianScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010a60, 0x010a7f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOldTurkicScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010c00, 0x010c48 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOldUyghurScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010f70, 0x010f89 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodePalmyreneScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010860, 0x01087f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodePauCinHauScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011ac0, 0x011af8 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodePhagsPaScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x00a840, 0x00a877 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodePhoenicianScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x01091f,
    };
    const ranges = [_][2]u21{
        .{ 0x010900, 0x01091b },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodePsalterPahlaviScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010b80, 0x010b91 }, .{ 0x010b99, 0x010b9c }, .{ 0x010ba9, 0x010baf },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeRejangScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00a95f,
    };
    const ranges = [_][2]u21{
        .{ 0x00a930, 0x00a953 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeRunicScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x0016a0, 0x0016ea }, .{ 0x0016ee, 0x0016f8 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeNewTaiLueScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x001980, 0x0019ab }, .{ 0x0019b0, 0x0019c9 }, .{ 0x0019d0, 0x0019da },
        .{ 0x0019de, 0x0019df },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSamaritanScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x000800, 0x00082d }, .{ 0x000830, 0x00083e },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSaurashtraScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x00a880, 0x00a8c5 }, .{ 0x00a8ce, 0x00a8d9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSharadaScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011180, 0x0111df }, .{ 0x011b60, 0x011b67 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeShavianScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010450, 0x01047f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSiddhamScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011580, 0x0115b5 }, .{ 0x0115b8, 0x0115dd },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSideticScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010940, 0x010959 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSignWritingScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x01d800, 0x01da8b }, .{ 0x01da9b, 0x01da9f }, .{ 0x01daa1, 0x01daaf },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSinhalaScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000dbd, 0x000dca, 0x000dd6,
    };
    const ranges = [_][2]u21{
        .{ 0x000d81, 0x000d83 }, .{ 0x000d85, 0x000d96 }, .{ 0x000d9a, 0x000db1 },
        .{ 0x000db3, 0x000dbb }, .{ 0x000dc0, 0x000dc6 }, .{ 0x000dcf, 0x000dd4 },
        .{ 0x000dd8, 0x000ddf }, .{ 0x000de6, 0x000def }, .{ 0x000df2, 0x000df4 },
        .{ 0x0111e1, 0x0111f4 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSogdianScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010f30, 0x010f59 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSoraSompengScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x0110d0, 0x0110e8 }, .{ 0x0110f0, 0x0110f9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSoyomboScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011a50, 0x011aa2 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSundaneseScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x001b80, 0x001bbf }, .{ 0x001cc0, 0x001cc7 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSunuwarScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011bc0, 0x011be1 }, .{ 0x011bf0, 0x011bf9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSylotiNagriScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x00a800, 0x00a82c },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSyriacScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x000700, 0x00070d }, .{ 0x00070f, 0x00074a }, .{ 0x00074d, 0x00074f },
        .{ 0x000860, 0x00086a },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTagalogScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00171f,
    };
    const ranges = [_][2]u21{
        .{ 0x001700, 0x001715 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTagbanwaScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x001760, 0x00176c }, .{ 0x00176e, 0x001770 }, .{ 0x001772, 0x001773 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTaiLeScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x001950, 0x00196d }, .{ 0x001970, 0x001974 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTaiThamScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x001a20, 0x001a5e }, .{ 0x001a60, 0x001a7c }, .{ 0x001a7f, 0x001a89 },
        .{ 0x001a90, 0x001a99 }, .{ 0x001aa0, 0x001aad },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTaiVietScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x00aa80, 0x00aac2 }, .{ 0x00aadb, 0x00aadf },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTaiYoScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x01e6c0, 0x01e6de }, .{ 0x01e6e0, 0x01e6f5 }, .{ 0x01e6fe, 0x01e6ff },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTakriScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011680, 0x0116b9 }, .{ 0x0116c0, 0x0116c9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTamilScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000b9c, 0x000bd0, 0x000bd7, 0x011fff,
    };
    const ranges = [_][2]u21{
        .{ 0x000b82, 0x000b83 }, .{ 0x000b85, 0x000b8a }, .{ 0x000b8e, 0x000b90 },
        .{ 0x000b92, 0x000b95 }, .{ 0x000b99, 0x000b9a }, .{ 0x000b9e, 0x000b9f },
        .{ 0x000ba3, 0x000ba4 }, .{ 0x000ba8, 0x000baa }, .{ 0x000bae, 0x000bb9 },
        .{ 0x000bbe, 0x000bc2 }, .{ 0x000bc6, 0x000bc8 }, .{ 0x000bca, 0x000bcd },
        .{ 0x000be6, 0x000bfa }, .{ 0x011fc0, 0x011ff1 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTangsaScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x016a70, 0x016abe }, .{ 0x016ac0, 0x016ac9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTangutScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x016fe0,
    };
    const ranges = [_][2]u21{
        .{ 0x017000, 0x018aff }, .{ 0x018d00, 0x018d1e }, .{ 0x018d80, 0x018df2 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTeluguScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x000c00, 0x000c0c }, .{ 0x000c0e, 0x000c10 }, .{ 0x000c12, 0x000c28 },
        .{ 0x000c2a, 0x000c39 }, .{ 0x000c3c, 0x000c44 }, .{ 0x000c46, 0x000c48 },
        .{ 0x000c4a, 0x000c4d }, .{ 0x000c55, 0x000c56 }, .{ 0x000c58, 0x000c5a },
        .{ 0x000c5c, 0x000c5d }, .{ 0x000c60, 0x000c63 }, .{ 0x000c66, 0x000c6f },
        .{ 0x000c77, 0x000c7f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeThaanaScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x000780, 0x0007b1 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeThaiScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x000e01, 0x000e3a }, .{ 0x000e40, 0x000e5b },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTibetanScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x000f00, 0x000f47 }, .{ 0x000f49, 0x000f6c }, .{ 0x000f71, 0x000f97 },
        .{ 0x000f99, 0x000fbc }, .{ 0x000fbe, 0x000fcc }, .{ 0x000fce, 0x000fd4 },
        .{ 0x000fd9, 0x000fda },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTifinaghScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x002d7f,
    };
    const ranges = [_][2]u21{
        .{ 0x002d30, 0x002d67 }, .{ 0x002d6f, 0x002d70 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTirhutaScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011480, 0x0114c7 }, .{ 0x0114d0, 0x0114d9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTodhriScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x0105c0, 0x0105f3 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTolongSikiScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011db0, 0x011ddb }, .{ 0x011de0, 0x011de9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTotoScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x01e290, 0x01e2ae },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeTuluTigalariScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x01138b, 0x01138e, 0x0113c2, 0x0113c5,
    };
    const ranges = [_][2]u21{
        .{ 0x011380, 0x011389 }, .{ 0x011390, 0x0113b5 }, .{ 0x0113b7, 0x0113c0 },
        .{ 0x0113c7, 0x0113ca }, .{ 0x0113cc, 0x0113d5 }, .{ 0x0113d7, 0x0113d8 },
        .{ 0x0113e1, 0x0113e2 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeUgariticScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x01039f,
    };
    const ranges = [_][2]u21{
        .{ 0x010380, 0x01039d },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeVaiScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x00a500, 0x00a62b },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeUnknownScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00038b, 0x00038d, 0x0003a2, 0x000530, 0x000590, 0x00070e, 0x00083f, 0x00085f,
        0x000984, 0x0009a9, 0x0009b1, 0x0009de, 0x000a04, 0x000a29, 0x000a31, 0x000a34,
        0x000a37, 0x000a3d, 0x000a5d, 0x000a84, 0x000a8e, 0x000a92, 0x000aa9, 0x000ab1,
        0x000ab4, 0x000ac6, 0x000aca, 0x000b00, 0x000b04, 0x000b29, 0x000b31, 0x000b34,
        0x000b5e, 0x000b84, 0x000b91, 0x000b9b, 0x000b9d, 0x000bc9, 0x000c0d, 0x000c11,
        0x000c29, 0x000c45, 0x000c49, 0x000c57, 0x000c5b, 0x000c8d, 0x000c91, 0x000ca9,
        0x000cb4, 0x000cc5, 0x000cc9, 0x000cdf, 0x000cf0, 0x000d0d, 0x000d11, 0x000d45,
        0x000d49, 0x000d80, 0x000d84, 0x000db2, 0x000dbc, 0x000dd5, 0x000dd7, 0x000e83,
        0x000e85, 0x000e8b, 0x000ea4, 0x000ea6, 0x000ec5, 0x000ec7, 0x000ecf, 0x000f48,
        0x000f98, 0x000fbd, 0x000fcd, 0x0010c6, 0x001249, 0x001257, 0x001259, 0x001289,
        0x0012b1, 0x0012bf, 0x0012c1, 0x0012d7, 0x001311, 0x00176d, 0x001771, 0x00191f,
        0x001a5f, 0x001b4d, 0x001f58, 0x001f5a, 0x001f5c, 0x001f5e, 0x001fb5, 0x001fc5,
        0x001fdc, 0x001ff5, 0x001fff, 0x002065, 0x00208f, 0x002d26, 0x002da7, 0x002daf,
        0x002db7, 0x002dbf, 0x002dc7, 0x002dcf, 0x002dd7, 0x002ddf, 0x002e9a, 0x003040,
        0x003130, 0x00318f, 0x00321f, 0x00a9ce, 0x00a9ff, 0x00ab27, 0x00ab2f, 0x00fb37,
        0x00fb3d, 0x00fb3f, 0x00fb42, 0x00fb45, 0x00fe53, 0x00fe67, 0x00fe75, 0x00ff00,
        0x00ffe7, 0x01000c, 0x010027, 0x01003b, 0x01003e, 0x01018f, 0x01039e, 0x01057b,
        0x01058b, 0x010593, 0x010596, 0x0105a2, 0x0105b2, 0x0105ba, 0x010786, 0x0107b1,
        0x010809, 0x010836, 0x010856, 0x0108f3, 0x010a04, 0x010a14, 0x010a18, 0x010e7f,
        0x010eaa, 0x011135, 0x0111e0, 0x011212, 0x011287, 0x011289, 0x01128e, 0x01129e,
        0x011304, 0x011329, 0x011331, 0x011334, 0x01133a, 0x01138a, 0x01138f, 0x0113b6,
        0x0113c1, 0x0113c6, 0x0113cb, 0x0113d6, 0x01145c, 0x011914, 0x011917, 0x011936,
        0x011c09, 0x011c37, 0x011ca8, 0x011d07, 0x011d0a, 0x011d3b, 0x011d3e, 0x011d66,
        0x011d69, 0x011d8f, 0x011d92, 0x011f11, 0x01246f, 0x016a5f, 0x016abf, 0x016b5a,
        0x016b62, 0x01aff4, 0x01affc, 0x01afff, 0x01d455, 0x01d49d, 0x01d4ad, 0x01d4ba,
        0x01d4bc, 0x01d4c4, 0x01d506, 0x01d515, 0x01d51d, 0x01d53a, 0x01d53f, 0x01d545,
        0x01d551, 0x01daa0, 0x01e007, 0x01e022, 0x01e025, 0x01e6df, 0x01e7e7, 0x01e7ec,
        0x01e7ef, 0x01e7ff, 0x01ee04, 0x01ee20, 0x01ee23, 0x01ee28, 0x01ee33, 0x01ee38,
        0x01ee3a, 0x01ee48, 0x01ee4a, 0x01ee4c, 0x01ee50, 0x01ee53, 0x01ee58, 0x01ee5a,
        0x01ee5c, 0x01ee5e, 0x01ee60, 0x01ee63, 0x01ee6b, 0x01ee73, 0x01ee78, 0x01ee7d,
        0x01ee7f, 0x01ee8a, 0x01eea4, 0x01eeaa, 0x01f0c0, 0x01f0d0, 0x01fac7, 0x01fb93,
    };
    const ranges = [_][2]u21{
        .{ 0x000378, 0x000379 }, .{ 0x000380, 0x000383 },
        .{ 0x000557, 0x000558 }, .{ 0x00058b, 0x00058c },
        .{ 0x0005c8, 0x0005cf }, .{ 0x0005eb, 0x0005ee },
        .{ 0x0005f5, 0x0005ff }, .{ 0x00074b, 0x00074c },
        .{ 0x0007b2, 0x0007bf }, .{ 0x0007fb, 0x0007fc },
        .{ 0x00082e, 0x00082f }, .{ 0x00085c, 0x00085d },
        .{ 0x00086b, 0x00086f }, .{ 0x000892, 0x000896 },
        .{ 0x00098d, 0x00098e }, .{ 0x000991, 0x000992 },
        .{ 0x0009b3, 0x0009b5 }, .{ 0x0009ba, 0x0009bb },
        .{ 0x0009c5, 0x0009c6 }, .{ 0x0009c9, 0x0009ca },
        .{ 0x0009cf, 0x0009d6 }, .{ 0x0009d8, 0x0009db },
        .{ 0x0009e4, 0x0009e5 }, .{ 0x0009ff, 0x000a00 },
        .{ 0x000a0b, 0x000a0e }, .{ 0x000a11, 0x000a12 },
        .{ 0x000a3a, 0x000a3b }, .{ 0x000a43, 0x000a46 },
        .{ 0x000a49, 0x000a4a }, .{ 0x000a4e, 0x000a50 },
        .{ 0x000a52, 0x000a58 }, .{ 0x000a5f, 0x000a65 },
        .{ 0x000a77, 0x000a80 }, .{ 0x000aba, 0x000abb },
        .{ 0x000ace, 0x000acf }, .{ 0x000ad1, 0x000adf },
        .{ 0x000ae4, 0x000ae5 }, .{ 0x000af2, 0x000af8 },
        .{ 0x000b0d, 0x000b0e }, .{ 0x000b11, 0x000b12 },
        .{ 0x000b3a, 0x000b3b }, .{ 0x000b45, 0x000b46 },
        .{ 0x000b49, 0x000b4a }, .{ 0x000b4e, 0x000b54 },
        .{ 0x000b58, 0x000b5b }, .{ 0x000b64, 0x000b65 },
        .{ 0x000b78, 0x000b81 }, .{ 0x000b8b, 0x000b8d },
        .{ 0x000b96, 0x000b98 }, .{ 0x000ba0, 0x000ba2 },
        .{ 0x000ba5, 0x000ba7 }, .{ 0x000bab, 0x000bad },
        .{ 0x000bba, 0x000bbd }, .{ 0x000bc3, 0x000bc5 },
        .{ 0x000bce, 0x000bcf }, .{ 0x000bd1, 0x000bd6 },
        .{ 0x000bd8, 0x000be5 }, .{ 0x000bfb, 0x000bff },
        .{ 0x000c3a, 0x000c3b }, .{ 0x000c4e, 0x000c54 },
        .{ 0x000c5e, 0x000c5f }, .{ 0x000c64, 0x000c65 },
        .{ 0x000c70, 0x000c76 }, .{ 0x000cba, 0x000cbb },
        .{ 0x000cce, 0x000cd4 }, .{ 0x000cd7, 0x000cdb },
        .{ 0x000ce4, 0x000ce5 }, .{ 0x000cf4, 0x000cff },
        .{ 0x000d50, 0x000d53 }, .{ 0x000d64, 0x000d65 },
        .{ 0x000d97, 0x000d99 }, .{ 0x000dbe, 0x000dbf },
        .{ 0x000dc7, 0x000dc9 }, .{ 0x000dcb, 0x000dce },
        .{ 0x000de0, 0x000de5 }, .{ 0x000df0, 0x000df1 },
        .{ 0x000df5, 0x000e00 }, .{ 0x000e3b, 0x000e3e },
        .{ 0x000e5c, 0x000e80 }, .{ 0x000ebe, 0x000ebf },
        .{ 0x000eda, 0x000edb }, .{ 0x000ee0, 0x000eff },
        .{ 0x000f6d, 0x000f70 }, .{ 0x000fdb, 0x000fff },
        .{ 0x0010c8, 0x0010cc }, .{ 0x0010ce, 0x0010cf },
        .{ 0x00124e, 0x00124f }, .{ 0x00125e, 0x00125f },
        .{ 0x00128e, 0x00128f }, .{ 0x0012b6, 0x0012b7 },
        .{ 0x0012c6, 0x0012c7 }, .{ 0x001316, 0x001317 },
        .{ 0x00135b, 0x00135c }, .{ 0x00137d, 0x00137f },
        .{ 0x00139a, 0x00139f }, .{ 0x0013f6, 0x0013f7 },
        .{ 0x0013fe, 0x0013ff }, .{ 0x00169d, 0x00169f },
        .{ 0x0016f9, 0x0016ff }, .{ 0x001716, 0x00171e },
        .{ 0x001737, 0x00173f }, .{ 0x001754, 0x00175f },
        .{ 0x001774, 0x00177f }, .{ 0x0017de, 0x0017df },
        .{ 0x0017ea, 0x0017ef }, .{ 0x0017fa, 0x0017ff },
        .{ 0x00181a, 0x00181f }, .{ 0x001879, 0x00187f },
        .{ 0x0018ab, 0x0018af }, .{ 0x0018f6, 0x0018ff },
        .{ 0x00192c, 0x00192f }, .{ 0x00193c, 0x00193f },
        .{ 0x001941, 0x001943 }, .{ 0x00196e, 0x00196f },
        .{ 0x001975, 0x00197f }, .{ 0x0019ac, 0x0019af },
        .{ 0x0019ca, 0x0019cf }, .{ 0x0019db, 0x0019dd },
        .{ 0x001a1c, 0x001a1d }, .{ 0x001a7d, 0x001a7e },
        .{ 0x001a8a, 0x001a8f }, .{ 0x001a9a, 0x001a9f },
        .{ 0x001aae, 0x001aaf }, .{ 0x001ade, 0x001adf },
        .{ 0x001aec, 0x001aff }, .{ 0x001bf4, 0x001bfb },
        .{ 0x001c38, 0x001c3a }, .{ 0x001c4a, 0x001c4c },
        .{ 0x001c8b, 0x001c8f }, .{ 0x001cbb, 0x001cbc },
        .{ 0x001cc8, 0x001ccf }, .{ 0x001cfb, 0x001cff },
        .{ 0x001f16, 0x001f17 }, .{ 0x001f1e, 0x001f1f },
        .{ 0x001f46, 0x001f47 }, .{ 0x001f4e, 0x001f4f },
        .{ 0x001f7e, 0x001f7f }, .{ 0x001fd4, 0x001fd5 },
        .{ 0x001ff0, 0x001ff1 }, .{ 0x002072, 0x002073 },
        .{ 0x00209d, 0x00209f }, .{ 0x0020c2, 0x0020cf },
        .{ 0x0020f1, 0x0020ff }, .{ 0x00218c, 0x00218f },
        .{ 0x00242a, 0x00243f }, .{ 0x00244b, 0x00245f },
        .{ 0x002b74, 0x002b75 }, .{ 0x002cf4, 0x002cf8 },
        .{ 0x002d28, 0x002d2c }, .{ 0x002d2e, 0x002d2f },
        .{ 0x002d68, 0x002d6e }, .{ 0x002d71, 0x002d7e },
        .{ 0x002d97, 0x002d9f }, .{ 0x002e5e, 0x002e7f },
        .{ 0x002ef4, 0x002eff }, .{ 0x002fd6, 0x002fef },
        .{ 0x003097, 0x003098 }, .{ 0x003100, 0x003104 },
        .{ 0x0031e6, 0x0031ee }, .{ 0x00a48d, 0x00a48f },
        .{ 0x00a4c7, 0x00a4cf }, .{ 0x00a62c, 0x00a63f },
        .{ 0x00a6f8, 0x00a6ff }, .{ 0x00a7dd, 0x00a7f0 },
        .{ 0x00a82d, 0x00a82f }, .{ 0x00a83a, 0x00a83f },
        .{ 0x00a878, 0x00a87f }, .{ 0x00a8c6, 0x00a8cd },
        .{ 0x00a8da, 0x00a8df }, .{ 0x00a954, 0x00a95e },
        .{ 0x00a97d, 0x00a97f }, .{ 0x00a9da, 0x00a9dd },
        .{ 0x00aa37, 0x00aa3f }, .{ 0x00aa4e, 0x00aa4f },
        .{ 0x00aa5a, 0x00aa5b }, .{ 0x00aac3, 0x00aada },
        .{ 0x00aaf7, 0x00ab00 }, .{ 0x00ab07, 0x00ab08 },
        .{ 0x00ab0f, 0x00ab10 }, .{ 0x00ab17, 0x00ab1f },
        .{ 0x00ab6c, 0x00ab6f }, .{ 0x00abee, 0x00abef },
        .{ 0x00abfa, 0x00abff }, .{ 0x00d7a4, 0x00d7af },
        .{ 0x00d7c7, 0x00d7ca }, .{ 0x00d7fc, 0x00dfff },
        .{ 0x00e000, 0x00f8ff }, .{ 0x00fa6e, 0x00fa6f },
        .{ 0x00fada, 0x00faff }, .{ 0x00fb07, 0x00fb12 },
        .{ 0x00fb18, 0x00fb1c }, .{ 0x00fdd0, 0x00fdef },
        .{ 0x00fe1a, 0x00fe1f }, .{ 0x00fe6c, 0x00fe6f },
        .{ 0x00fefd, 0x00fefe }, .{ 0x00ffbf, 0x00ffc1 },
        .{ 0x00ffc8, 0x00ffc9 }, .{ 0x00ffd0, 0x00ffd1 },
        .{ 0x00ffd8, 0x00ffd9 }, .{ 0x00ffdd, 0x00ffdf },
        .{ 0x00ffef, 0x00fff8 }, .{ 0x00fffe, 0x00ffff },
        .{ 0x01004e, 0x01004f }, .{ 0x01005e, 0x01007f },
        .{ 0x0100fb, 0x0100ff }, .{ 0x010103, 0x010106 },
        .{ 0x010134, 0x010136 }, .{ 0x01019d, 0x01019f },
        .{ 0x0101a1, 0x0101cf }, .{ 0x0101fe, 0x01027f },
        .{ 0x01029d, 0x01029f }, .{ 0x0102d1, 0x0102df },
        .{ 0x0102fc, 0x0102ff }, .{ 0x010324, 0x01032c },
        .{ 0x01034b, 0x01034f }, .{ 0x01037b, 0x01037f },
        .{ 0x0103c4, 0x0103c7 }, .{ 0x0103d6, 0x0103ff },
        .{ 0x01049e, 0x01049f }, .{ 0x0104aa, 0x0104af },
        .{ 0x0104d4, 0x0104d7 }, .{ 0x0104fc, 0x0104ff },
        .{ 0x010528, 0x01052f }, .{ 0x010564, 0x01056e },
        .{ 0x0105bd, 0x0105bf }, .{ 0x0105f4, 0x0105ff },
        .{ 0x010737, 0x01073f }, .{ 0x010756, 0x01075f },
        .{ 0x010768, 0x01077f }, .{ 0x0107bb, 0x0107ff },
        .{ 0x010806, 0x010807 }, .{ 0x010839, 0x01083b },
        .{ 0x01083d, 0x01083e }, .{ 0x01089f, 0x0108a6 },
        .{ 0x0108b0, 0x0108df }, .{ 0x0108f6, 0x0108fa },
        .{ 0x01091c, 0x01091e }, .{ 0x01093a, 0x01093e },
        .{ 0x01095a, 0x01097f }, .{ 0x0109b8, 0x0109bb },
        .{ 0x0109d0, 0x0109d1 }, .{ 0x010a07, 0x010a0b },
        .{ 0x010a36, 0x010a37 }, .{ 0x010a3b, 0x010a3e },
        .{ 0x010a49, 0x010a4f }, .{ 0x010a59, 0x010a5f },
        .{ 0x010aa0, 0x010abf }, .{ 0x010ae7, 0x010aea },
        .{ 0x010af7, 0x010aff }, .{ 0x010b36, 0x010b38 },
        .{ 0x010b56, 0x010b57 }, .{ 0x010b73, 0x010b77 },
        .{ 0x010b92, 0x010b98 }, .{ 0x010b9d, 0x010ba8 },
        .{ 0x010bb0, 0x010bff }, .{ 0x010c49, 0x010c7f },
        .{ 0x010cb3, 0x010cbf }, .{ 0x010cf3, 0x010cf9 },
        .{ 0x010d28, 0x010d2f }, .{ 0x010d3a, 0x010d3f },
        .{ 0x010d66, 0x010d68 }, .{ 0x010d86, 0x010d8d },
        .{ 0x010d90, 0x010e5f }, .{ 0x010eae, 0x010eaf },
        .{ 0x010eb2, 0x010ec1 }, .{ 0x010ec8, 0x010ecf },
        .{ 0x010ed9, 0x010ef9 }, .{ 0x010f28, 0x010f2f },
        .{ 0x010f5a, 0x010f6f }, .{ 0x010f8a, 0x010faf },
        .{ 0x010fcc, 0x010fdf }, .{ 0x010ff7, 0x010fff },
        .{ 0x01104e, 0x011051 }, .{ 0x011076, 0x01107e },
        .{ 0x0110c3, 0x0110cc }, .{ 0x0110ce, 0x0110cf },
        .{ 0x0110e9, 0x0110ef }, .{ 0x0110fa, 0x0110ff },
        .{ 0x011148, 0x01114f }, .{ 0x011177, 0x01117f },
        .{ 0x0111f5, 0x0111ff }, .{ 0x011242, 0x01127f },
        .{ 0x0112aa, 0x0112af }, .{ 0x0112eb, 0x0112ef },
        .{ 0x0112fa, 0x0112ff }, .{ 0x01130d, 0x01130e },
        .{ 0x011311, 0x011312 }, .{ 0x011345, 0x011346 },
        .{ 0x011349, 0x01134a }, .{ 0x01134e, 0x01134f },
        .{ 0x011351, 0x011356 }, .{ 0x011358, 0x01135c },
        .{ 0x011364, 0x011365 }, .{ 0x01136d, 0x01136f },
        .{ 0x011375, 0x01137f }, .{ 0x01138c, 0x01138d },
        .{ 0x0113c3, 0x0113c4 }, .{ 0x0113d9, 0x0113e0 },
        .{ 0x0113e3, 0x0113ff }, .{ 0x011462, 0x01147f },
        .{ 0x0114c8, 0x0114cf }, .{ 0x0114da, 0x01157f },
        .{ 0x0115b6, 0x0115b7 }, .{ 0x0115de, 0x0115ff },
        .{ 0x011645, 0x01164f }, .{ 0x01165a, 0x01165f },
        .{ 0x01166d, 0x01167f }, .{ 0x0116ba, 0x0116bf },
        .{ 0x0116ca, 0x0116cf }, .{ 0x0116e4, 0x0116ff },
        .{ 0x01171b, 0x01171c }, .{ 0x01172c, 0x01172f },
        .{ 0x011747, 0x0117ff }, .{ 0x01183c, 0x01189f },
        .{ 0x0118f3, 0x0118fe }, .{ 0x011907, 0x011908 },
        .{ 0x01190a, 0x01190b }, .{ 0x011939, 0x01193a },
        .{ 0x011947, 0x01194f }, .{ 0x01195a, 0x01199f },
        .{ 0x0119a8, 0x0119a9 }, .{ 0x0119d8, 0x0119d9 },
        .{ 0x0119e5, 0x0119ff }, .{ 0x011a48, 0x011a4f },
        .{ 0x011aa3, 0x011aaf }, .{ 0x011af9, 0x011aff },
        .{ 0x011b0a, 0x011b5f }, .{ 0x011b68, 0x011bbf },
        .{ 0x011be2, 0x011bef }, .{ 0x011bfa, 0x011bff },
        .{ 0x011c46, 0x011c4f }, .{ 0x011c6d, 0x011c6f },
        .{ 0x011c90, 0x011c91 }, .{ 0x011cb7, 0x011cff },
        .{ 0x011d37, 0x011d39 }, .{ 0x011d48, 0x011d4f },
        .{ 0x011d5a, 0x011d5f }, .{ 0x011d99, 0x011d9f },
        .{ 0x011daa, 0x011daf }, .{ 0x011ddc, 0x011ddf },
        .{ 0x011dea, 0x011edf }, .{ 0x011ef9, 0x011eff },
        .{ 0x011f3b, 0x011f3d }, .{ 0x011f5b, 0x011faf },
        .{ 0x011fb1, 0x011fbf }, .{ 0x011ff2, 0x011ffe },
        .{ 0x01239a, 0x0123ff }, .{ 0x012475, 0x01247f },
        .{ 0x012544, 0x012f8f }, .{ 0x012ff3, 0x012fff },
        .{ 0x013456, 0x01345f }, .{ 0x0143fb, 0x0143ff },
        .{ 0x014647, 0x0160ff }, .{ 0x01613a, 0x0167ff },
        .{ 0x016a39, 0x016a3f }, .{ 0x016a6a, 0x016a6d },
        .{ 0x016aca, 0x016acf }, .{ 0x016aee, 0x016aef },
        .{ 0x016af6, 0x016aff }, .{ 0x016b46, 0x016b4f },
        .{ 0x016b78, 0x016b7c }, .{ 0x016b90, 0x016d3f },
        .{ 0x016d7a, 0x016e3f }, .{ 0x016e9b, 0x016e9f },
        .{ 0x016eb9, 0x016eba }, .{ 0x016ed4, 0x016eff },
        .{ 0x016f4b, 0x016f4e }, .{ 0x016f88, 0x016f8e },
        .{ 0x016fa0, 0x016fdf }, .{ 0x016fe5, 0x016fef },
        .{ 0x016ff7, 0x016fff }, .{ 0x018cd6, 0x018cfe },
        .{ 0x018d1f, 0x018d7f }, .{ 0x018df3, 0x01afef },
        .{ 0x01b123, 0x01b131 }, .{ 0x01b133, 0x01b14f },
        .{ 0x01b153, 0x01b154 }, .{ 0x01b156, 0x01b163 },
        .{ 0x01b168, 0x01b16f }, .{ 0x01b2fc, 0x01bbff },
        .{ 0x01bc6b, 0x01bc6f }, .{ 0x01bc7d, 0x01bc7f },
        .{ 0x01bc89, 0x01bc8f }, .{ 0x01bc9a, 0x01bc9b },
        .{ 0x01bca4, 0x01cbff }, .{ 0x01ccfd, 0x01ccff },
        .{ 0x01ceb4, 0x01ceb9 }, .{ 0x01ced1, 0x01cedf },
        .{ 0x01cef1, 0x01ceff }, .{ 0x01cf2e, 0x01cf2f },
        .{ 0x01cf47, 0x01cf4f }, .{ 0x01cfc4, 0x01cfff },
        .{ 0x01d0f6, 0x01d0ff }, .{ 0x01d127, 0x01d128 },
        .{ 0x01d1eb, 0x01d1ff }, .{ 0x01d246, 0x01d2bf },
        .{ 0x01d2d4, 0x01d2df }, .{ 0x01d2f4, 0x01d2ff },
        .{ 0x01d357, 0x01d35f }, .{ 0x01d379, 0x01d3ff },
        .{ 0x01d4a0, 0x01d4a1 }, .{ 0x01d4a3, 0x01d4a4 },
        .{ 0x01d4a7, 0x01d4a8 }, .{ 0x01d50b, 0x01d50c },
        .{ 0x01d547, 0x01d549 }, .{ 0x01d6a6, 0x01d6a7 },
        .{ 0x01d7cc, 0x01d7cd }, .{ 0x01da8c, 0x01da9a },
        .{ 0x01dab0, 0x01deff }, .{ 0x01df1f, 0x01df24 },
        .{ 0x01df2b, 0x01dfff }, .{ 0x01e019, 0x01e01a },
        .{ 0x01e02b, 0x01e02f }, .{ 0x01e06e, 0x01e08e },
        .{ 0x01e090, 0x01e0ff }, .{ 0x01e12d, 0x01e12f },
        .{ 0x01e13e, 0x01e13f }, .{ 0x01e14a, 0x01e14d },
        .{ 0x01e150, 0x01e28f }, .{ 0x01e2af, 0x01e2bf },
        .{ 0x01e2fa, 0x01e2fe }, .{ 0x01e300, 0x01e4cf },
        .{ 0x01e4fa, 0x01e5cf }, .{ 0x01e5fb, 0x01e5fe },
        .{ 0x01e600, 0x01e6bf }, .{ 0x01e6f6, 0x01e6fd },
        .{ 0x01e700, 0x01e7df }, .{ 0x01e8c5, 0x01e8c6 },
        .{ 0x01e8d7, 0x01e8ff }, .{ 0x01e94c, 0x01e94f },
        .{ 0x01e95a, 0x01e95d }, .{ 0x01e960, 0x01ec70 },
        .{ 0x01ecb5, 0x01ed00 }, .{ 0x01ed3e, 0x01edff },
        .{ 0x01ee25, 0x01ee26 }, .{ 0x01ee3c, 0x01ee41 },
        .{ 0x01ee43, 0x01ee46 }, .{ 0x01ee55, 0x01ee56 },
        .{ 0x01ee65, 0x01ee66 }, .{ 0x01ee9c, 0x01eea0 },
        .{ 0x01eebc, 0x01eeef }, .{ 0x01eef2, 0x01efff },
        .{ 0x01f02c, 0x01f02f }, .{ 0x01f094, 0x01f09f },
        .{ 0x01f0af, 0x01f0b0 }, .{ 0x01f0f6, 0x01f0ff },
        .{ 0x01f1ae, 0x01f1e5 }, .{ 0x01f203, 0x01f20f },
        .{ 0x01f23c, 0x01f23f }, .{ 0x01f249, 0x01f24f },
        .{ 0x01f252, 0x01f25f }, .{ 0x01f266, 0x01f2ff },
        .{ 0x01f6d9, 0x01f6db }, .{ 0x01f6ed, 0x01f6ef },
        .{ 0x01f6fd, 0x01f6ff }, .{ 0x01f7da, 0x01f7df },
        .{ 0x01f7ec, 0x01f7ef }, .{ 0x01f7f1, 0x01f7ff },
        .{ 0x01f80c, 0x01f80f }, .{ 0x01f848, 0x01f84f },
        .{ 0x01f85a, 0x01f85f }, .{ 0x01f888, 0x01f88f },
        .{ 0x01f8ae, 0x01f8af }, .{ 0x01f8bc, 0x01f8bf },
        .{ 0x01f8c2, 0x01f8cf }, .{ 0x01f8d9, 0x01f8ff },
        .{ 0x01fa58, 0x01fa5f }, .{ 0x01fa6e, 0x01fa6f },
        .{ 0x01fa7d, 0x01fa7f }, .{ 0x01fa8b, 0x01fa8d },
        .{ 0x01fac9, 0x01facc }, .{ 0x01fadd, 0x01fade },
        .{ 0x01faeb, 0x01faee }, .{ 0x01faf9, 0x01faff },
        .{ 0x01fbfb, 0x01ffff }, .{ 0x02a6e0, 0x02a6ff },
        .{ 0x02b81e, 0x02b81f }, .{ 0x02ceae, 0x02ceaf },
        .{ 0x02ebe1, 0x02ebef }, .{ 0x02ee5e, 0x02f7ff },
        .{ 0x02fa1e, 0x02ffff }, .{ 0x03134b, 0x03134f },
        .{ 0x03347a, 0x0e0000 }, .{ 0x0e0002, 0x0e001f },
        .{ 0x0e0080, 0x0e00ff }, .{ 0x0e01f0, 0x10ffff },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeVithkuqiScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010570, 0x01057a }, .{ 0x01057c, 0x01058a }, .{ 0x01058c, 0x010592 },
        .{ 0x010594, 0x010595 }, .{ 0x010597, 0x0105a1 }, .{ 0x0105a3, 0x0105b1 },
        .{ 0x0105b3, 0x0105b9 }, .{ 0x0105bb, 0x0105bc },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeWanchoScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x01e2ff,
    };
    const ranges = [_][2]u21{
        .{ 0x01e2c0, 0x01e2f9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeWarangCitiScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0118ff,
    };
    const ranges = [_][2]u21{
        .{ 0x0118a0, 0x0118f2 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeYezidiScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010e80, 0x010ea9 }, .{ 0x010eab, 0x010ead }, .{ 0x010eb0, 0x010eb1 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeYiScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x00a000, 0x00a48c }, .{ 0x00a490, 0x00a4c6 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeZanabazarSquareScriptCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011a00, 0x011a47 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeCommonScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000d7, 0x0000f7, 0x0002c8, 0x0002cc, 0x0002d8, 0x00037e,
        0x000385, 0x000387, 0x000605, 0x0006dd, 0x0008e2, 0x000e3f,
        0x002e42, 0x003000, 0x003004, 0x003012, 0x003020, 0x003036,
        0x00327f, 0x0033ff, 0x00ab5b, 0x00feff, 0x01d4a2, 0x01d4bb,
        0x01d546, 0x01f7f0, 0x01fac8, 0x0e0001,
    };
    const ranges = [_][2]u21{
        .{ 0x000000, 0x000040 },
        .{ 0x00005b, 0x000060 },
        .{ 0x00007b, 0x0000a9 },
        .{ 0x0000ab, 0x0000b6 },
        .{ 0x0000b8, 0x0000b9 },
        .{ 0x0000bb, 0x0000bf },
        .{ 0x0002b9, 0x0002bb },
        .{ 0x0002bd, 0x0002c6 },
        .{ 0x0002ce, 0x0002d6 },
        .{ 0x0002da, 0x0002df },
        .{ 0x0002e5, 0x0002e9 },
        .{ 0x0002ec, 0x0002ff },
        .{ 0x000fd5, 0x000fd8 },
        .{ 0x002000, 0x00200b },
        .{ 0x00200e, 0x00202e },
        .{ 0x002030, 0x00204e },
        .{ 0x002050, 0x002059 },
        .{ 0x00205b, 0x00205c },
        .{ 0x00205e, 0x002064 },
        .{ 0x002066, 0x002070 },
        .{ 0x002074, 0x00207e },
        .{ 0x002080, 0x00208e },
        .{ 0x0020a0, 0x0020c1 },
        .{ 0x002100, 0x002125 },
        .{ 0x002127, 0x002129 },
        .{ 0x00212c, 0x002131 },
        .{ 0x002133, 0x00214d },
        .{ 0x00214f, 0x00215f },
        .{ 0x002189, 0x00218b },
        .{ 0x002190, 0x002429 },
        .{ 0x002440, 0x00244a },
        .{ 0x002460, 0x0027ff },
        .{ 0x002900, 0x002b73 },
        .{ 0x002b76, 0x002bff },
        .{ 0x002e00, 0x002e16 },
        .{ 0x002e18, 0x002e2f },
        .{ 0x002e32, 0x002e3b },
        .{ 0x002e3d, 0x002e40 },
        .{ 0x002e44, 0x002e5d },
        .{ 0x003248, 0x00325f },
        .{ 0x0032b1, 0x0032bf },
        .{ 0x0032cc, 0x0032cf },
        .{ 0x003371, 0x00337a },
        .{ 0x003380, 0x0033df },
        .{ 0x004dc0, 0x004dff },
        .{ 0x00a708, 0x00a721 },
        .{ 0x00a788, 0x00a78a },
        .{ 0x00ab6a, 0x00ab6b },
        .{ 0x00fe10, 0x00fe19 },
        .{ 0x00fe30, 0x00fe44 },
        .{ 0x00fe47, 0x00fe52 },
        .{ 0x00fe54, 0x00fe66 },
        .{ 0x00fe68, 0x00fe6b },
        .{ 0x00ff01, 0x00ff20 },
        .{ 0x00ff3b, 0x00ff40 },
        .{ 0x00ff5b, 0x00ff60 },
        .{ 0x00ffe0, 0x00ffe6 },
        .{ 0x00ffe8, 0x00ffee },
        .{ 0x00fff9, 0x00fffd },
        .{ 0x010190, 0x01019c },
        .{ 0x0101d0, 0x0101fc },
        .{ 0x01cc00, 0x01ccfc },
        .{ 0x01cd00, 0x01ceb3 },
        .{ 0x01ceba, 0x01ced0 },
        .{ 0x01cee0, 0x01cef0 },
        .{ 0x01cf50, 0x01cfc3 },
        .{ 0x01d000, 0x01d0f5 },
        .{ 0x01d100, 0x01d126 },
        .{ 0x01d129, 0x01d166 },
        .{ 0x01d16a, 0x01d17a },
        .{ 0x01d183, 0x01d184 },
        .{ 0x01d18c, 0x01d1a9 },
        .{ 0x01d1ae, 0x01d1ea },
        .{ 0x01d2c0, 0x01d2d3 },
        .{ 0x01d2e0, 0x01d2f3 },
        .{ 0x01d300, 0x01d356 },
        .{ 0x01d372, 0x01d378 },
        .{ 0x01d400, 0x01d454 },
        .{ 0x01d456, 0x01d49c },
        .{ 0x01d49e, 0x01d49f },
        .{ 0x01d4a5, 0x01d4a6 },
        .{ 0x01d4a9, 0x01d4ac },
        .{ 0x01d4ae, 0x01d4b9 },
        .{ 0x01d4bd, 0x01d4c3 },
        .{ 0x01d4c5, 0x01d505 },
        .{ 0x01d507, 0x01d50a },
        .{ 0x01d50d, 0x01d514 },
        .{ 0x01d516, 0x01d51c },
        .{ 0x01d51e, 0x01d539 },
        .{ 0x01d53b, 0x01d53e },
        .{ 0x01d540, 0x01d544 },
        .{ 0x01d54a, 0x01d550 },
        .{ 0x01d552, 0x01d6a5 },
        .{ 0x01d6a8, 0x01d7cb },
        .{ 0x01d7ce, 0x01d7ff },
        .{ 0x01ec71, 0x01ecb4 },
        .{ 0x01ed01, 0x01ed3d },
        .{ 0x01f000, 0x01f02b },
        .{ 0x01f030, 0x01f093 },
        .{ 0x01f0a0, 0x01f0ae },
        .{ 0x01f0b1, 0x01f0bf },
        .{ 0x01f0c1, 0x01f0cf },
        .{ 0x01f0d1, 0x01f0f5 },
        .{ 0x01f100, 0x01f1ad },
        .{ 0x01f1e6, 0x01f1ff },
        .{ 0x01f201, 0x01f202 },
        .{ 0x01f210, 0x01f23b },
        .{ 0x01f240, 0x01f248 },
        .{ 0x01f260, 0x01f265 },
        .{ 0x01f300, 0x01f6d8 },
        .{ 0x01f6dc, 0x01f6ec },
        .{ 0x01f6f0, 0x01f6fc },
        .{ 0x01f700, 0x01f7d9 },
        .{ 0x01f7e0, 0x01f7eb },
        .{ 0x01f800, 0x01f80b },
        .{ 0x01f810, 0x01f847 },
        .{ 0x01f850, 0x01f859 },
        .{ 0x01f860, 0x01f887 },
        .{ 0x01f890, 0x01f8ad },
        .{ 0x01f8b0, 0x01f8bb },
        .{ 0x01f8c0, 0x01f8c1 },
        .{ 0x01f8d0, 0x01f8d8 },
        .{ 0x01f900, 0x01fa57 },
        .{ 0x01fa60, 0x01fa6d },
        .{ 0x01fa70, 0x01fa7c },
        .{ 0x01fa80, 0x01fa8a },
        .{ 0x01fa8e, 0x01fac6 },
        .{ 0x01facd, 0x01fadc },
        .{ 0x01fadf, 0x01faea },
        .{ 0x01faef, 0x01faf8 },
        .{ 0x01fb00, 0x01fb92 },
        .{ 0x01fb94, 0x01fbfa },
        .{ 0x0e0020, 0x0e007f },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeCopticScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x000300 or
        code_point == 0x000307 or
        code_point == 0x002e17 or
        (code_point >= 0x000304 and code_point <= 0x000305) or
        (code_point >= 0x000374 and code_point <= 0x000375) or
        (code_point >= 0x0003e2 and code_point <= 0x0003ef) or
        (code_point >= 0x002c80 and code_point <= 0x002cf3) or
        (code_point >= 0x002cf9 and code_point <= 0x002cff) or
        (code_point >= 0x0102e0 and code_point <= 0x0102fb);
}

pub fn isUnicodeNumberCategoryCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000b9, 0x002070, 0x002cfd, 0x003007, 0x010341, 0x01034a,
    };
    const ranges = [_][2]u21{
        .{ 0x000030, 0x000039 },
        .{ 0x0000b2, 0x0000b3 },
        .{ 0x0000bc, 0x0000be },
        .{ 0x000660, 0x000669 },
        .{ 0x0006f0, 0x0006f9 },
        .{ 0x0007c0, 0x0007c9 },
        .{ 0x000966, 0x00096f },
        .{ 0x0009e6, 0x0009ef },
        .{ 0x0009f4, 0x0009f9 },
        .{ 0x000a66, 0x000a6f },
        .{ 0x000ae6, 0x000aef },
        .{ 0x000b66, 0x000b6f },
        .{ 0x000b72, 0x000b77 },
        .{ 0x000be6, 0x000bf2 },
        .{ 0x000c66, 0x000c6f },
        .{ 0x000c78, 0x000c7e },
        .{ 0x000ce6, 0x000cef },
        .{ 0x000d58, 0x000d5e },
        .{ 0x000d66, 0x000d78 },
        .{ 0x000de6, 0x000def },
        .{ 0x000e50, 0x000e59 },
        .{ 0x000ed0, 0x000ed9 },
        .{ 0x000f20, 0x000f33 },
        .{ 0x001040, 0x001049 },
        .{ 0x001090, 0x001099 },
        .{ 0x001369, 0x00137c },
        .{ 0x0016ee, 0x0016f0 },
        .{ 0x0017e0, 0x0017e9 },
        .{ 0x0017f0, 0x0017f9 },
        .{ 0x001810, 0x001819 },
        .{ 0x001946, 0x00194f },
        .{ 0x0019d0, 0x0019da },
        .{ 0x001a80, 0x001a89 },
        .{ 0x001a90, 0x001a99 },
        .{ 0x001b50, 0x001b59 },
        .{ 0x001bb0, 0x001bb9 },
        .{ 0x001c40, 0x001c49 },
        .{ 0x001c50, 0x001c59 },
        .{ 0x002074, 0x002079 },
        .{ 0x002080, 0x002089 },
        .{ 0x002150, 0x002182 },
        .{ 0x002185, 0x002189 },
        .{ 0x002460, 0x00249b },
        .{ 0x0024ea, 0x0024ff },
        .{ 0x002776, 0x002793 },
        .{ 0x003021, 0x003029 },
        .{ 0x003038, 0x00303a },
        .{ 0x003192, 0x003195 },
        .{ 0x003220, 0x003229 },
        .{ 0x003248, 0x00324f },
        .{ 0x003251, 0x00325f },
        .{ 0x003280, 0x003289 },
        .{ 0x0032b1, 0x0032bf },
        .{ 0x00a620, 0x00a629 },
        .{ 0x00a6e6, 0x00a6ef },
        .{ 0x00a830, 0x00a835 },
        .{ 0x00a8d0, 0x00a8d9 },
        .{ 0x00a900, 0x00a909 },
        .{ 0x00a9d0, 0x00a9d9 },
        .{ 0x00a9f0, 0x00a9f9 },
        .{ 0x00aa50, 0x00aa59 },
        .{ 0x00abf0, 0x00abf9 },
        .{ 0x00ff10, 0x00ff19 },
        .{ 0x010107, 0x010133 },
        .{ 0x010140, 0x010178 },
        .{ 0x01018a, 0x01018b },
        .{ 0x0102e1, 0x0102fb },
        .{ 0x010320, 0x010323 },
        .{ 0x0103d1, 0x0103d5 },
        .{ 0x0104a0, 0x0104a9 },
        .{ 0x010858, 0x01085f },
        .{ 0x010879, 0x01087f },
        .{ 0x0108a7, 0x0108af },
        .{ 0x0108fb, 0x0108ff },
        .{ 0x010916, 0x01091b },
        .{ 0x0109bc, 0x0109bd },
        .{ 0x0109c0, 0x0109cf },
        .{ 0x0109d2, 0x0109ff },
        .{ 0x010a40, 0x010a48 },
        .{ 0x010a7d, 0x010a7e },
        .{ 0x010a9d, 0x010a9f },
        .{ 0x010aeb, 0x010aef },
        .{ 0x010b58, 0x010b5f },
        .{ 0x010b78, 0x010b7f },
        .{ 0x010ba9, 0x010baf },
        .{ 0x010cfa, 0x010cff },
        .{ 0x010d30, 0x010d39 },
        .{ 0x010d40, 0x010d49 },
        .{ 0x010e60, 0x010e7e },
        .{ 0x010f1d, 0x010f26 },
        .{ 0x010f51, 0x010f54 },
        .{ 0x010fc5, 0x010fcb },
        .{ 0x011052, 0x01106f },
        .{ 0x0110f0, 0x0110f9 },
        .{ 0x011136, 0x01113f },
        .{ 0x0111d0, 0x0111d9 },
        .{ 0x0111e1, 0x0111f4 },
        .{ 0x0112f0, 0x0112f9 },
        .{ 0x011450, 0x011459 },
        .{ 0x0114d0, 0x0114d9 },
        .{ 0x011650, 0x011659 },
        .{ 0x0116c0, 0x0116c9 },
        .{ 0x0116d0, 0x0116e3 },
        .{ 0x011730, 0x01173b },
        .{ 0x0118e0, 0x0118f2 },
        .{ 0x011950, 0x011959 },
        .{ 0x011bf0, 0x011bf9 },
        .{ 0x011c50, 0x011c6c },
        .{ 0x011d50, 0x011d59 },
        .{ 0x011da0, 0x011da9 },
        .{ 0x011de0, 0x011de9 },
        .{ 0x011f50, 0x011f59 },
        .{ 0x011fc0, 0x011fd4 },
        .{ 0x012400, 0x01246e },
        .{ 0x016130, 0x016139 },
        .{ 0x016a60, 0x016a69 },
        .{ 0x016ac0, 0x016ac9 },
        .{ 0x016b50, 0x016b59 },
        .{ 0x016b5b, 0x016b61 },
        .{ 0x016d70, 0x016d79 },
        .{ 0x016e80, 0x016e96 },
        .{ 0x016ff4, 0x016ff6 },
        .{ 0x01ccf0, 0x01ccf9 },
        .{ 0x01d2c0, 0x01d2d3 },
        .{ 0x01d2e0, 0x01d2f3 },
        .{ 0x01d360, 0x01d378 },
        .{ 0x01d7ce, 0x01d7ff },
        .{ 0x01e140, 0x01e149 },
        .{ 0x01e2f0, 0x01e2f9 },
        .{ 0x01e4f0, 0x01e4f9 },
        .{ 0x01e5f1, 0x01e5fa },
        .{ 0x01e8c7, 0x01e8cf },
        .{ 0x01e950, 0x01e959 },
        .{ 0x01ec71, 0x01ecab },
        .{ 0x01ecad, 0x01ecaf },
        .{ 0x01ecb1, 0x01ecb4 },
        .{ 0x01ed01, 0x01ed2d },
        .{ 0x01ed2f, 0x01ed3d },
        .{ 0x01f100, 0x01f10c },
        .{ 0x01fbf0, 0x01fbf9 },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeIdContinueCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00005f, 0x0000aa, 0x0000b5, 0x0000b7, 0x0000ba, 0x0002ec, 0x0002ee, 0x00037f,
        0x00038c, 0x000559, 0x0005bf, 0x0005c7, 0x0006ff, 0x0007fa, 0x0007fd, 0x0009b2,
        0x0009d7, 0x0009fc, 0x0009fe, 0x000a3c, 0x000a51, 0x000a5e, 0x000ad0, 0x000b71,
        0x000b9c, 0x000bd0, 0x000bd7, 0x000dbd, 0x000dca, 0x000dd6, 0x000e84, 0x000ea5,
        0x000ec6, 0x000f00, 0x000f35, 0x000f37, 0x000f39, 0x000fc6, 0x0010c7, 0x0010cd,
        0x001258, 0x0012c0, 0x0017d7, 0x001aa7, 0x001f59, 0x001f5b, 0x001f5d, 0x001fbe,
        0x002054, 0x002071, 0x00207f, 0x0020e1, 0x002102, 0x002107, 0x002115, 0x002124,
        0x002126, 0x002128, 0x00214e, 0x002d27, 0x002d2d, 0x002d6f, 0x00a82c, 0x00a8fb,
        0x00fb3e, 0x00ff3f, 0x0101fd, 0x0102e0, 0x010808, 0x01083c, 0x010a3f, 0x010f27,
        0x0110c2, 0x011176, 0x0111dc, 0x011288, 0x011350, 0x011357, 0x01138b, 0x01138e,
        0x0113c2, 0x0113c5, 0x0114c7, 0x011644, 0x011909, 0x011a47, 0x011a9d, 0x011d3a,
        0x011fb0, 0x01b132, 0x01b155, 0x01d4a2, 0x01d4bb, 0x01d546, 0x01da75, 0x01da84,
        0x01e08f, 0x01e14e, 0x01ee24, 0x01ee27, 0x01ee39, 0x01ee3b, 0x01ee42, 0x01ee47,
        0x01ee49, 0x01ee4b, 0x01ee54, 0x01ee57, 0x01ee59, 0x01ee5b, 0x01ee5d, 0x01ee5f,
        0x01ee64, 0x01ee7e,
    };
    const ranges = [_][2]u21{
        .{ 0x000030, 0x000039 }, .{ 0x000041, 0x00005a }, .{ 0x000061, 0x00007a },
        .{ 0x0000c0, 0x0000d6 }, .{ 0x0000d8, 0x0000f6 }, .{ 0x0000f8, 0x0002c1 },
        .{ 0x0002c6, 0x0002d1 }, .{ 0x0002e0, 0x0002e4 }, .{ 0x000300, 0x000374 },
        .{ 0x000376, 0x000377 }, .{ 0x00037a, 0x00037d }, .{ 0x000386, 0x00038a },
        .{ 0x00038e, 0x0003a1 }, .{ 0x0003a3, 0x0003f5 }, .{ 0x0003f7, 0x000481 },
        .{ 0x000483, 0x000487 }, .{ 0x00048a, 0x00052f }, .{ 0x000531, 0x000556 },
        .{ 0x000560, 0x000588 }, .{ 0x000591, 0x0005bd }, .{ 0x0005c1, 0x0005c2 },
        .{ 0x0005c4, 0x0005c5 }, .{ 0x0005d0, 0x0005ea }, .{ 0x0005ef, 0x0005f2 },
        .{ 0x000610, 0x00061a }, .{ 0x000620, 0x000669 }, .{ 0x00066e, 0x0006d3 },
        .{ 0x0006d5, 0x0006dc }, .{ 0x0006df, 0x0006e8 }, .{ 0x0006ea, 0x0006fc },
        .{ 0x000710, 0x00074a }, .{ 0x00074d, 0x0007b1 }, .{ 0x0007c0, 0x0007f5 },
        .{ 0x000800, 0x00082d }, .{ 0x000840, 0x00085b }, .{ 0x000860, 0x00086a },
        .{ 0x000870, 0x000887 }, .{ 0x000889, 0x00088f }, .{ 0x000897, 0x0008e1 },
        .{ 0x0008e3, 0x000963 }, .{ 0x000966, 0x00096f }, .{ 0x000971, 0x000983 },
        .{ 0x000985, 0x00098c }, .{ 0x00098f, 0x000990 }, .{ 0x000993, 0x0009a8 },
        .{ 0x0009aa, 0x0009b0 }, .{ 0x0009b6, 0x0009b9 }, .{ 0x0009bc, 0x0009c4 },
        .{ 0x0009c7, 0x0009c8 }, .{ 0x0009cb, 0x0009ce }, .{ 0x0009dc, 0x0009dd },
        .{ 0x0009df, 0x0009e3 }, .{ 0x0009e6, 0x0009f1 }, .{ 0x000a01, 0x000a03 },
        .{ 0x000a05, 0x000a0a }, .{ 0x000a0f, 0x000a10 }, .{ 0x000a13, 0x000a28 },
        .{ 0x000a2a, 0x000a30 }, .{ 0x000a32, 0x000a33 }, .{ 0x000a35, 0x000a36 },
        .{ 0x000a38, 0x000a39 }, .{ 0x000a3e, 0x000a42 }, .{ 0x000a47, 0x000a48 },
        .{ 0x000a4b, 0x000a4d }, .{ 0x000a59, 0x000a5c }, .{ 0x000a66, 0x000a75 },
        .{ 0x000a81, 0x000a83 }, .{ 0x000a85, 0x000a8d }, .{ 0x000a8f, 0x000a91 },
        .{ 0x000a93, 0x000aa8 }, .{ 0x000aaa, 0x000ab0 }, .{ 0x000ab2, 0x000ab3 },
        .{ 0x000ab5, 0x000ab9 }, .{ 0x000abc, 0x000ac5 }, .{ 0x000ac7, 0x000ac9 },
        .{ 0x000acb, 0x000acd }, .{ 0x000ae0, 0x000ae3 }, .{ 0x000ae6, 0x000aef },
        .{ 0x000af9, 0x000aff }, .{ 0x000b01, 0x000b03 }, .{ 0x000b05, 0x000b0c },
        .{ 0x000b0f, 0x000b10 }, .{ 0x000b13, 0x000b28 }, .{ 0x000b2a, 0x000b30 },
        .{ 0x000b32, 0x000b33 }, .{ 0x000b35, 0x000b39 }, .{ 0x000b3c, 0x000b44 },
        .{ 0x000b47, 0x000b48 }, .{ 0x000b4b, 0x000b4d }, .{ 0x000b55, 0x000b57 },
        .{ 0x000b5c, 0x000b5d }, .{ 0x000b5f, 0x000b63 }, .{ 0x000b66, 0x000b6f },
        .{ 0x000b82, 0x000b83 }, .{ 0x000b85, 0x000b8a }, .{ 0x000b8e, 0x000b90 },
        .{ 0x000b92, 0x000b95 }, .{ 0x000b99, 0x000b9a }, .{ 0x000b9e, 0x000b9f },
        .{ 0x000ba3, 0x000ba4 }, .{ 0x000ba8, 0x000baa }, .{ 0x000bae, 0x000bb9 },
        .{ 0x000bbe, 0x000bc2 }, .{ 0x000bc6, 0x000bc8 }, .{ 0x000bca, 0x000bcd },
        .{ 0x000be6, 0x000bef }, .{ 0x000c00, 0x000c0c }, .{ 0x000c0e, 0x000c10 },
        .{ 0x000c12, 0x000c28 }, .{ 0x000c2a, 0x000c39 }, .{ 0x000c3c, 0x000c44 },
        .{ 0x000c46, 0x000c48 }, .{ 0x000c4a, 0x000c4d }, .{ 0x000c55, 0x000c56 },
        .{ 0x000c58, 0x000c5a }, .{ 0x000c5c, 0x000c5d }, .{ 0x000c60, 0x000c63 },
        .{ 0x000c66, 0x000c6f }, .{ 0x000c80, 0x000c83 }, .{ 0x000c85, 0x000c8c },
        .{ 0x000c8e, 0x000c90 }, .{ 0x000c92, 0x000ca8 }, .{ 0x000caa, 0x000cb3 },
        .{ 0x000cb5, 0x000cb9 }, .{ 0x000cbc, 0x000cc4 }, .{ 0x000cc6, 0x000cc8 },
        .{ 0x000cca, 0x000ccd }, .{ 0x000cd5, 0x000cd6 }, .{ 0x000cdc, 0x000cde },
        .{ 0x000ce0, 0x000ce3 }, .{ 0x000ce6, 0x000cef }, .{ 0x000cf1, 0x000cf3 },
        .{ 0x000d00, 0x000d0c }, .{ 0x000d0e, 0x000d10 }, .{ 0x000d12, 0x000d44 },
        .{ 0x000d46, 0x000d48 }, .{ 0x000d4a, 0x000d4e }, .{ 0x000d54, 0x000d57 },
        .{ 0x000d5f, 0x000d63 }, .{ 0x000d66, 0x000d6f }, .{ 0x000d7a, 0x000d7f },
        .{ 0x000d81, 0x000d83 }, .{ 0x000d85, 0x000d96 }, .{ 0x000d9a, 0x000db1 },
        .{ 0x000db3, 0x000dbb }, .{ 0x000dc0, 0x000dc6 }, .{ 0x000dcf, 0x000dd4 },
        .{ 0x000dd8, 0x000ddf }, .{ 0x000de6, 0x000def }, .{ 0x000df2, 0x000df3 },
        .{ 0x000e01, 0x000e3a }, .{ 0x000e40, 0x000e4e }, .{ 0x000e50, 0x000e59 },
        .{ 0x000e81, 0x000e82 }, .{ 0x000e86, 0x000e8a }, .{ 0x000e8c, 0x000ea3 },
        .{ 0x000ea7, 0x000ebd }, .{ 0x000ec0, 0x000ec4 }, .{ 0x000ec8, 0x000ece },
        .{ 0x000ed0, 0x000ed9 }, .{ 0x000edc, 0x000edf }, .{ 0x000f18, 0x000f19 },
        .{ 0x000f20, 0x000f29 }, .{ 0x000f3e, 0x000f47 }, .{ 0x000f49, 0x000f6c },
        .{ 0x000f71, 0x000f84 }, .{ 0x000f86, 0x000f97 }, .{ 0x000f99, 0x000fbc },
        .{ 0x001000, 0x001049 }, .{ 0x001050, 0x00109d }, .{ 0x0010a0, 0x0010c5 },
        .{ 0x0010d0, 0x0010fa }, .{ 0x0010fc, 0x001248 }, .{ 0x00124a, 0x00124d },
        .{ 0x001250, 0x001256 }, .{ 0x00125a, 0x00125d }, .{ 0x001260, 0x001288 },
        .{ 0x00128a, 0x00128d }, .{ 0x001290, 0x0012b0 }, .{ 0x0012b2, 0x0012b5 },
        .{ 0x0012b8, 0x0012be }, .{ 0x0012c2, 0x0012c5 }, .{ 0x0012c8, 0x0012d6 },
        .{ 0x0012d8, 0x001310 }, .{ 0x001312, 0x001315 }, .{ 0x001318, 0x00135a },
        .{ 0x00135d, 0x00135f }, .{ 0x001369, 0x001371 }, .{ 0x001380, 0x00138f },
        .{ 0x0013a0, 0x0013f5 }, .{ 0x0013f8, 0x0013fd }, .{ 0x001401, 0x00166c },
        .{ 0x00166f, 0x00167f }, .{ 0x001681, 0x00169a }, .{ 0x0016a0, 0x0016ea },
        .{ 0x0016ee, 0x0016f8 }, .{ 0x001700, 0x001715 }, .{ 0x00171f, 0x001734 },
        .{ 0x001740, 0x001753 }, .{ 0x001760, 0x00176c }, .{ 0x00176e, 0x001770 },
        .{ 0x001772, 0x001773 }, .{ 0x001780, 0x0017d3 }, .{ 0x0017dc, 0x0017dd },
        .{ 0x0017e0, 0x0017e9 }, .{ 0x00180b, 0x00180d }, .{ 0x00180f, 0x001819 },
        .{ 0x001820, 0x001878 }, .{ 0x001880, 0x0018aa }, .{ 0x0018b0, 0x0018f5 },
        .{ 0x001900, 0x00191e }, .{ 0x001920, 0x00192b }, .{ 0x001930, 0x00193b },
        .{ 0x001946, 0x00196d }, .{ 0x001970, 0x001974 }, .{ 0x001980, 0x0019ab },
        .{ 0x0019b0, 0x0019c9 }, .{ 0x0019d0, 0x0019da }, .{ 0x001a00, 0x001a1b },
        .{ 0x001a20, 0x001a5e }, .{ 0x001a60, 0x001a7c }, .{ 0x001a7f, 0x001a89 },
        .{ 0x001a90, 0x001a99 }, .{ 0x001ab0, 0x001abd }, .{ 0x001abf, 0x001add },
        .{ 0x001ae0, 0x001aeb }, .{ 0x001b00, 0x001b4c }, .{ 0x001b50, 0x001b59 },
        .{ 0x001b6b, 0x001b73 }, .{ 0x001b80, 0x001bf3 }, .{ 0x001c00, 0x001c37 },
        .{ 0x001c40, 0x001c49 }, .{ 0x001c4d, 0x001c7d }, .{ 0x001c80, 0x001c8a },
        .{ 0x001c90, 0x001cba }, .{ 0x001cbd, 0x001cbf }, .{ 0x001cd0, 0x001cd2 },
        .{ 0x001cd4, 0x001cfa }, .{ 0x001d00, 0x001f15 }, .{ 0x001f18, 0x001f1d },
        .{ 0x001f20, 0x001f45 }, .{ 0x001f48, 0x001f4d }, .{ 0x001f50, 0x001f57 },
        .{ 0x001f5f, 0x001f7d }, .{ 0x001f80, 0x001fb4 }, .{ 0x001fb6, 0x001fbc },
        .{ 0x001fc2, 0x001fc4 }, .{ 0x001fc6, 0x001fcc }, .{ 0x001fd0, 0x001fd3 },
        .{ 0x001fd6, 0x001fdb }, .{ 0x001fe0, 0x001fec }, .{ 0x001ff2, 0x001ff4 },
        .{ 0x001ff6, 0x001ffc }, .{ 0x00200c, 0x00200d }, .{ 0x00203f, 0x002040 },
        .{ 0x002090, 0x00209c }, .{ 0x0020d0, 0x0020dc }, .{ 0x0020e5, 0x0020f0 },
        .{ 0x00210a, 0x002113 }, .{ 0x002118, 0x00211d }, .{ 0x00212a, 0x002139 },
        .{ 0x00213c, 0x00213f }, .{ 0x002145, 0x002149 }, .{ 0x002160, 0x002188 },
        .{ 0x002c00, 0x002ce4 }, .{ 0x002ceb, 0x002cf3 }, .{ 0x002d00, 0x002d25 },
        .{ 0x002d30, 0x002d67 }, .{ 0x002d7f, 0x002d96 }, .{ 0x002da0, 0x002da6 },
        .{ 0x002da8, 0x002dae }, .{ 0x002db0, 0x002db6 }, .{ 0x002db8, 0x002dbe },
        .{ 0x002dc0, 0x002dc6 }, .{ 0x002dc8, 0x002dce }, .{ 0x002dd0, 0x002dd6 },
        .{ 0x002dd8, 0x002dde }, .{ 0x002de0, 0x002dff }, .{ 0x003005, 0x003007 },
        .{ 0x003021, 0x00302f }, .{ 0x003031, 0x003035 }, .{ 0x003038, 0x00303c },
        .{ 0x003041, 0x003096 }, .{ 0x003099, 0x00309f }, .{ 0x0030a1, 0x0030ff },
        .{ 0x003105, 0x00312f }, .{ 0x003131, 0x00318e }, .{ 0x0031a0, 0x0031bf },
        .{ 0x0031f0, 0x0031ff }, .{ 0x003400, 0x004dbf }, .{ 0x004e00, 0x00a48c },
        .{ 0x00a4d0, 0x00a4fd }, .{ 0x00a500, 0x00a60c }, .{ 0x00a610, 0x00a62b },
        .{ 0x00a640, 0x00a66f }, .{ 0x00a674, 0x00a67d }, .{ 0x00a67f, 0x00a6f1 },
        .{ 0x00a717, 0x00a71f }, .{ 0x00a722, 0x00a788 }, .{ 0x00a78b, 0x00a7dc },
        .{ 0x00a7f1, 0x00a827 }, .{ 0x00a840, 0x00a873 }, .{ 0x00a880, 0x00a8c5 },
        .{ 0x00a8d0, 0x00a8d9 }, .{ 0x00a8e0, 0x00a8f7 }, .{ 0x00a8fd, 0x00a92d },
        .{ 0x00a930, 0x00a953 }, .{ 0x00a960, 0x00a97c }, .{ 0x00a980, 0x00a9c0 },
        .{ 0x00a9cf, 0x00a9d9 }, .{ 0x00a9e0, 0x00a9fe }, .{ 0x00aa00, 0x00aa36 },
        .{ 0x00aa40, 0x00aa4d }, .{ 0x00aa50, 0x00aa59 }, .{ 0x00aa60, 0x00aa76 },
        .{ 0x00aa7a, 0x00aac2 }, .{ 0x00aadb, 0x00aadd }, .{ 0x00aae0, 0x00aaef },
        .{ 0x00aaf2, 0x00aaf6 }, .{ 0x00ab01, 0x00ab06 }, .{ 0x00ab09, 0x00ab0e },
        .{ 0x00ab11, 0x00ab16 }, .{ 0x00ab20, 0x00ab26 }, .{ 0x00ab28, 0x00ab2e },
        .{ 0x00ab30, 0x00ab5a }, .{ 0x00ab5c, 0x00ab69 }, .{ 0x00ab70, 0x00abea },
        .{ 0x00abec, 0x00abed }, .{ 0x00abf0, 0x00abf9 }, .{ 0x00ac00, 0x00d7a3 },
        .{ 0x00d7b0, 0x00d7c6 }, .{ 0x00d7cb, 0x00d7fb }, .{ 0x00f900, 0x00fa6d },
        .{ 0x00fa70, 0x00fad9 }, .{ 0x00fb00, 0x00fb06 }, .{ 0x00fb13, 0x00fb17 },
        .{ 0x00fb1d, 0x00fb28 }, .{ 0x00fb2a, 0x00fb36 }, .{ 0x00fb38, 0x00fb3c },
        .{ 0x00fb40, 0x00fb41 }, .{ 0x00fb43, 0x00fb44 }, .{ 0x00fb46, 0x00fbb1 },
        .{ 0x00fbd3, 0x00fd3d }, .{ 0x00fd50, 0x00fd8f }, .{ 0x00fd92, 0x00fdc7 },
        .{ 0x00fdf0, 0x00fdfb }, .{ 0x00fe00, 0x00fe0f }, .{ 0x00fe20, 0x00fe2f },
        .{ 0x00fe33, 0x00fe34 }, .{ 0x00fe4d, 0x00fe4f }, .{ 0x00fe70, 0x00fe74 },
        .{ 0x00fe76, 0x00fefc }, .{ 0x00ff10, 0x00ff19 }, .{ 0x00ff21, 0x00ff3a },
        .{ 0x00ff41, 0x00ff5a }, .{ 0x00ff65, 0x00ffbe }, .{ 0x00ffc2, 0x00ffc7 },
        .{ 0x00ffca, 0x00ffcf }, .{ 0x00ffd2, 0x00ffd7 }, .{ 0x00ffda, 0x00ffdc },
        .{ 0x010000, 0x01000b }, .{ 0x01000d, 0x010026 }, .{ 0x010028, 0x01003a },
        .{ 0x01003c, 0x01003d }, .{ 0x01003f, 0x01004d }, .{ 0x010050, 0x01005d },
        .{ 0x010080, 0x0100fa }, .{ 0x010140, 0x010174 }, .{ 0x010280, 0x01029c },
        .{ 0x0102a0, 0x0102d0 }, .{ 0x010300, 0x01031f }, .{ 0x01032d, 0x01034a },
        .{ 0x010350, 0x01037a }, .{ 0x010380, 0x01039d }, .{ 0x0103a0, 0x0103c3 },
        .{ 0x0103c8, 0x0103cf }, .{ 0x0103d1, 0x0103d5 }, .{ 0x010400, 0x01049d },
        .{ 0x0104a0, 0x0104a9 }, .{ 0x0104b0, 0x0104d3 }, .{ 0x0104d8, 0x0104fb },
        .{ 0x010500, 0x010527 }, .{ 0x010530, 0x010563 }, .{ 0x010570, 0x01057a },
        .{ 0x01057c, 0x01058a }, .{ 0x01058c, 0x010592 }, .{ 0x010594, 0x010595 },
        .{ 0x010597, 0x0105a1 }, .{ 0x0105a3, 0x0105b1 }, .{ 0x0105b3, 0x0105b9 },
        .{ 0x0105bb, 0x0105bc }, .{ 0x0105c0, 0x0105f3 }, .{ 0x010600, 0x010736 },
        .{ 0x010740, 0x010755 }, .{ 0x010760, 0x010767 }, .{ 0x010780, 0x010785 },
        .{ 0x010787, 0x0107b0 }, .{ 0x0107b2, 0x0107ba }, .{ 0x010800, 0x010805 },
        .{ 0x01080a, 0x010835 }, .{ 0x010837, 0x010838 }, .{ 0x01083f, 0x010855 },
        .{ 0x010860, 0x010876 }, .{ 0x010880, 0x01089e }, .{ 0x0108e0, 0x0108f2 },
        .{ 0x0108f4, 0x0108f5 }, .{ 0x010900, 0x010915 }, .{ 0x010920, 0x010939 },
        .{ 0x010940, 0x010959 }, .{ 0x010980, 0x0109b7 }, .{ 0x0109be, 0x0109bf },
        .{ 0x010a00, 0x010a03 }, .{ 0x010a05, 0x010a06 }, .{ 0x010a0c, 0x010a13 },
        .{ 0x010a15, 0x010a17 }, .{ 0x010a19, 0x010a35 }, .{ 0x010a38, 0x010a3a },
        .{ 0x010a60, 0x010a7c }, .{ 0x010a80, 0x010a9c }, .{ 0x010ac0, 0x010ac7 },
        .{ 0x010ac9, 0x010ae6 }, .{ 0x010b00, 0x010b35 }, .{ 0x010b40, 0x010b55 },
        .{ 0x010b60, 0x010b72 }, .{ 0x010b80, 0x010b91 }, .{ 0x010c00, 0x010c48 },
        .{ 0x010c80, 0x010cb2 }, .{ 0x010cc0, 0x010cf2 }, .{ 0x010d00, 0x010d27 },
        .{ 0x010d30, 0x010d39 }, .{ 0x010d40, 0x010d65 }, .{ 0x010d69, 0x010d6d },
        .{ 0x010d6f, 0x010d85 }, .{ 0x010e80, 0x010ea9 }, .{ 0x010eab, 0x010eac },
        .{ 0x010eb0, 0x010eb1 }, .{ 0x010ec2, 0x010ec7 }, .{ 0x010efa, 0x010f1c },
        .{ 0x010f30, 0x010f50 }, .{ 0x010f70, 0x010f85 }, .{ 0x010fb0, 0x010fc4 },
        .{ 0x010fe0, 0x010ff6 }, .{ 0x011000, 0x011046 }, .{ 0x011066, 0x011075 },
        .{ 0x01107f, 0x0110ba }, .{ 0x0110d0, 0x0110e8 }, .{ 0x0110f0, 0x0110f9 },
        .{ 0x011100, 0x011134 }, .{ 0x011136, 0x01113f }, .{ 0x011144, 0x011147 },
        .{ 0x011150, 0x011173 }, .{ 0x011180, 0x0111c4 }, .{ 0x0111c9, 0x0111cc },
        .{ 0x0111ce, 0x0111da }, .{ 0x011200, 0x011211 }, .{ 0x011213, 0x011237 },
        .{ 0x01123e, 0x011241 }, .{ 0x011280, 0x011286 }, .{ 0x01128a, 0x01128d },
        .{ 0x01128f, 0x01129d }, .{ 0x01129f, 0x0112a8 }, .{ 0x0112b0, 0x0112ea },
        .{ 0x0112f0, 0x0112f9 }, .{ 0x011300, 0x011303 }, .{ 0x011305, 0x01130c },
        .{ 0x01130f, 0x011310 }, .{ 0x011313, 0x011328 }, .{ 0x01132a, 0x011330 },
        .{ 0x011332, 0x011333 }, .{ 0x011335, 0x011339 }, .{ 0x01133b, 0x011344 },
        .{ 0x011347, 0x011348 }, .{ 0x01134b, 0x01134d }, .{ 0x01135d, 0x011363 },
        .{ 0x011366, 0x01136c }, .{ 0x011370, 0x011374 }, .{ 0x011380, 0x011389 },
        .{ 0x011390, 0x0113b5 }, .{ 0x0113b7, 0x0113c0 }, .{ 0x0113c7, 0x0113ca },
        .{ 0x0113cc, 0x0113d3 }, .{ 0x0113e1, 0x0113e2 }, .{ 0x011400, 0x01144a },
        .{ 0x011450, 0x011459 }, .{ 0x01145e, 0x011461 }, .{ 0x011480, 0x0114c5 },
        .{ 0x0114d0, 0x0114d9 }, .{ 0x011580, 0x0115b5 }, .{ 0x0115b8, 0x0115c0 },
        .{ 0x0115d8, 0x0115dd }, .{ 0x011600, 0x011640 }, .{ 0x011650, 0x011659 },
        .{ 0x011680, 0x0116b8 }, .{ 0x0116c0, 0x0116c9 }, .{ 0x0116d0, 0x0116e3 },
        .{ 0x011700, 0x01171a }, .{ 0x01171d, 0x01172b }, .{ 0x011730, 0x011739 },
        .{ 0x011740, 0x011746 }, .{ 0x011800, 0x01183a }, .{ 0x0118a0, 0x0118e9 },
        .{ 0x0118ff, 0x011906 }, .{ 0x01190c, 0x011913 }, .{ 0x011915, 0x011916 },
        .{ 0x011918, 0x011935 }, .{ 0x011937, 0x011938 }, .{ 0x01193b, 0x011943 },
        .{ 0x011950, 0x011959 }, .{ 0x0119a0, 0x0119a7 }, .{ 0x0119aa, 0x0119d7 },
        .{ 0x0119da, 0x0119e1 }, .{ 0x0119e3, 0x0119e4 }, .{ 0x011a00, 0x011a3e },
        .{ 0x011a50, 0x011a99 }, .{ 0x011ab0, 0x011af8 }, .{ 0x011b60, 0x011b67 },
        .{ 0x011bc0, 0x011be0 }, .{ 0x011bf0, 0x011bf9 }, .{ 0x011c00, 0x011c08 },
        .{ 0x011c0a, 0x011c36 }, .{ 0x011c38, 0x011c40 }, .{ 0x011c50, 0x011c59 },
        .{ 0x011c72, 0x011c8f }, .{ 0x011c92, 0x011ca7 }, .{ 0x011ca9, 0x011cb6 },
        .{ 0x011d00, 0x011d06 }, .{ 0x011d08, 0x011d09 }, .{ 0x011d0b, 0x011d36 },
        .{ 0x011d3c, 0x011d3d }, .{ 0x011d3f, 0x011d47 }, .{ 0x011d50, 0x011d59 },
        .{ 0x011d60, 0x011d65 }, .{ 0x011d67, 0x011d68 }, .{ 0x011d6a, 0x011d8e },
        .{ 0x011d90, 0x011d91 }, .{ 0x011d93, 0x011d98 }, .{ 0x011da0, 0x011da9 },
        .{ 0x011db0, 0x011ddb }, .{ 0x011de0, 0x011de9 }, .{ 0x011ee0, 0x011ef6 },
        .{ 0x011f00, 0x011f10 }, .{ 0x011f12, 0x011f3a }, .{ 0x011f3e, 0x011f42 },
        .{ 0x011f50, 0x011f5a }, .{ 0x012000, 0x012399 }, .{ 0x012400, 0x01246e },
        .{ 0x012480, 0x012543 }, .{ 0x012f90, 0x012ff0 }, .{ 0x013000, 0x01342f },
        .{ 0x013440, 0x013455 }, .{ 0x013460, 0x0143fa }, .{ 0x014400, 0x014646 },
        .{ 0x016100, 0x016139 }, .{ 0x016800, 0x016a38 }, .{ 0x016a40, 0x016a5e },
        .{ 0x016a60, 0x016a69 }, .{ 0x016a70, 0x016abe }, .{ 0x016ac0, 0x016ac9 },
        .{ 0x016ad0, 0x016aed }, .{ 0x016af0, 0x016af4 }, .{ 0x016b00, 0x016b36 },
        .{ 0x016b40, 0x016b43 }, .{ 0x016b50, 0x016b59 }, .{ 0x016b63, 0x016b77 },
        .{ 0x016b7d, 0x016b8f }, .{ 0x016d40, 0x016d6c }, .{ 0x016d70, 0x016d79 },
        .{ 0x016e40, 0x016e7f }, .{ 0x016ea0, 0x016eb8 }, .{ 0x016ebb, 0x016ed3 },
        .{ 0x016f00, 0x016f4a }, .{ 0x016f4f, 0x016f87 }, .{ 0x016f8f, 0x016f9f },
        .{ 0x016fe0, 0x016fe1 }, .{ 0x016fe3, 0x016fe4 }, .{ 0x016ff0, 0x016ff6 },
        .{ 0x017000, 0x018cd5 }, .{ 0x018cff, 0x018d1e }, .{ 0x018d80, 0x018df2 },
        .{ 0x01aff0, 0x01aff3 }, .{ 0x01aff5, 0x01affb }, .{ 0x01affd, 0x01affe },
        .{ 0x01b000, 0x01b122 }, .{ 0x01b150, 0x01b152 }, .{ 0x01b164, 0x01b167 },
        .{ 0x01b170, 0x01b2fb }, .{ 0x01bc00, 0x01bc6a }, .{ 0x01bc70, 0x01bc7c },
        .{ 0x01bc80, 0x01bc88 }, .{ 0x01bc90, 0x01bc99 }, .{ 0x01bc9d, 0x01bc9e },
        .{ 0x01ccf0, 0x01ccf9 }, .{ 0x01cf00, 0x01cf2d }, .{ 0x01cf30, 0x01cf46 },
        .{ 0x01d165, 0x01d169 }, .{ 0x01d16d, 0x01d172 }, .{ 0x01d17b, 0x01d182 },
        .{ 0x01d185, 0x01d18b }, .{ 0x01d1aa, 0x01d1ad }, .{ 0x01d242, 0x01d244 },
        .{ 0x01d400, 0x01d454 }, .{ 0x01d456, 0x01d49c }, .{ 0x01d49e, 0x01d49f },
        .{ 0x01d4a5, 0x01d4a6 }, .{ 0x01d4a9, 0x01d4ac }, .{ 0x01d4ae, 0x01d4b9 },
        .{ 0x01d4bd, 0x01d4c3 }, .{ 0x01d4c5, 0x01d505 }, .{ 0x01d507, 0x01d50a },
        .{ 0x01d50d, 0x01d514 }, .{ 0x01d516, 0x01d51c }, .{ 0x01d51e, 0x01d539 },
        .{ 0x01d53b, 0x01d53e }, .{ 0x01d540, 0x01d544 }, .{ 0x01d54a, 0x01d550 },
        .{ 0x01d552, 0x01d6a5 }, .{ 0x01d6a8, 0x01d6c0 }, .{ 0x01d6c2, 0x01d6da },
        .{ 0x01d6dc, 0x01d6fa }, .{ 0x01d6fc, 0x01d714 }, .{ 0x01d716, 0x01d734 },
        .{ 0x01d736, 0x01d74e }, .{ 0x01d750, 0x01d76e }, .{ 0x01d770, 0x01d788 },
        .{ 0x01d78a, 0x01d7a8 }, .{ 0x01d7aa, 0x01d7c2 }, .{ 0x01d7c4, 0x01d7cb },
        .{ 0x01d7ce, 0x01d7ff }, .{ 0x01da00, 0x01da36 }, .{ 0x01da3b, 0x01da6c },
        .{ 0x01da9b, 0x01da9f }, .{ 0x01daa1, 0x01daaf }, .{ 0x01df00, 0x01df1e },
        .{ 0x01df25, 0x01df2a }, .{ 0x01e000, 0x01e006 }, .{ 0x01e008, 0x01e018 },
        .{ 0x01e01b, 0x01e021 }, .{ 0x01e023, 0x01e024 }, .{ 0x01e026, 0x01e02a },
        .{ 0x01e030, 0x01e06d }, .{ 0x01e100, 0x01e12c }, .{ 0x01e130, 0x01e13d },
        .{ 0x01e140, 0x01e149 }, .{ 0x01e290, 0x01e2ae }, .{ 0x01e2c0, 0x01e2f9 },
        .{ 0x01e4d0, 0x01e4f9 }, .{ 0x01e5d0, 0x01e5fa }, .{ 0x01e6c0, 0x01e6de },
        .{ 0x01e6e0, 0x01e6f5 }, .{ 0x01e6fe, 0x01e6ff }, .{ 0x01e7e0, 0x01e7e6 },
        .{ 0x01e7e8, 0x01e7eb }, .{ 0x01e7ed, 0x01e7ee }, .{ 0x01e7f0, 0x01e7fe },
        .{ 0x01e800, 0x01e8c4 }, .{ 0x01e8d0, 0x01e8d6 }, .{ 0x01e900, 0x01e94b },
        .{ 0x01e950, 0x01e959 }, .{ 0x01ee00, 0x01ee03 }, .{ 0x01ee05, 0x01ee1f },
        .{ 0x01ee21, 0x01ee22 }, .{ 0x01ee29, 0x01ee32 }, .{ 0x01ee34, 0x01ee37 },
        .{ 0x01ee4d, 0x01ee4f }, .{ 0x01ee51, 0x01ee52 }, .{ 0x01ee61, 0x01ee62 },
        .{ 0x01ee67, 0x01ee6a }, .{ 0x01ee6c, 0x01ee72 }, .{ 0x01ee74, 0x01ee77 },
        .{ 0x01ee79, 0x01ee7c }, .{ 0x01ee80, 0x01ee89 }, .{ 0x01ee8b, 0x01ee9b },
        .{ 0x01eea1, 0x01eea3 }, .{ 0x01eea5, 0x01eea9 }, .{ 0x01eeab, 0x01eebb },
        .{ 0x01fbf0, 0x01fbf9 }, .{ 0x020000, 0x02a6df }, .{ 0x02a700, 0x02b81d },
        .{ 0x02b820, 0x02cead }, .{ 0x02ceb0, 0x02ebe0 }, .{ 0x02ebf0, 0x02ee5d },
        .{ 0x02f800, 0x02fa1d }, .{ 0x030000, 0x03134a }, .{ 0x031350, 0x033479 },
        .{ 0x0e0100, 0x0e01ef },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}
pub fn isUnicodeXidContinueCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00005f, 0x0000aa, 0x0000b5, 0x0000b7, 0x0000ba, 0x0002ec, 0x0002ee, 0x00037f,
        0x00038c, 0x000559, 0x0005bf, 0x0005c7, 0x0006ff, 0x0007fa, 0x0007fd, 0x0009b2,
        0x0009d7, 0x0009fc, 0x0009fe, 0x000a3c, 0x000a51, 0x000a5e, 0x000ad0, 0x000b71,
        0x000b9c, 0x000bd0, 0x000bd7, 0x000dbd, 0x000dca, 0x000dd6, 0x000e84, 0x000ea5,
        0x000ec6, 0x000f00, 0x000f35, 0x000f37, 0x000f39, 0x000fc6, 0x0010c7, 0x0010cd,
        0x001258, 0x0012c0, 0x0017d7, 0x001aa7, 0x001f59, 0x001f5b, 0x001f5d, 0x001fbe,
        0x002054, 0x002071, 0x00207f, 0x0020e1, 0x002102, 0x002107, 0x002115, 0x002124,
        0x002126, 0x002128, 0x00214e, 0x002d27, 0x002d2d, 0x002d6f, 0x00a82c, 0x00a8fb,
        0x00fb3e, 0x00fe71, 0x00fe73, 0x00fe77, 0x00fe79, 0x00fe7b, 0x00fe7d, 0x00ff3f,
        0x0101fd, 0x0102e0, 0x010808, 0x01083c, 0x010a3f, 0x010f27, 0x0110c2, 0x011176,
        0x0111dc, 0x011288, 0x011350, 0x011357, 0x01138b, 0x01138e, 0x0113c2, 0x0113c5,
        0x0114c7, 0x011644, 0x011909, 0x011a47, 0x011a9d, 0x011d3a, 0x011fb0, 0x01b132,
        0x01b155, 0x01d4a2, 0x01d4bb, 0x01d546, 0x01da75, 0x01da84, 0x01e08f, 0x01e14e,
        0x01ee24, 0x01ee27, 0x01ee39, 0x01ee3b, 0x01ee42, 0x01ee47, 0x01ee49, 0x01ee4b,
        0x01ee54, 0x01ee57, 0x01ee59, 0x01ee5b, 0x01ee5d, 0x01ee5f, 0x01ee64, 0x01ee7e,
    };
    const ranges = [_][2]u21{
        .{ 0x000030, 0x000039 }, .{ 0x000041, 0x00005a }, .{ 0x000061, 0x00007a },
        .{ 0x0000c0, 0x0000d6 }, .{ 0x0000d8, 0x0000f6 }, .{ 0x0000f8, 0x0002c1 },
        .{ 0x0002c6, 0x0002d1 }, .{ 0x0002e0, 0x0002e4 }, .{ 0x000300, 0x000374 },
        .{ 0x000376, 0x000377 }, .{ 0x00037b, 0x00037d }, .{ 0x000386, 0x00038a },
        .{ 0x00038e, 0x0003a1 }, .{ 0x0003a3, 0x0003f5 }, .{ 0x0003f7, 0x000481 },
        .{ 0x000483, 0x000487 }, .{ 0x00048a, 0x00052f }, .{ 0x000531, 0x000556 },
        .{ 0x000560, 0x000588 }, .{ 0x000591, 0x0005bd }, .{ 0x0005c1, 0x0005c2 },
        .{ 0x0005c4, 0x0005c5 }, .{ 0x0005d0, 0x0005ea }, .{ 0x0005ef, 0x0005f2 },
        .{ 0x000610, 0x00061a }, .{ 0x000620, 0x000669 }, .{ 0x00066e, 0x0006d3 },
        .{ 0x0006d5, 0x0006dc }, .{ 0x0006df, 0x0006e8 }, .{ 0x0006ea, 0x0006fc },
        .{ 0x000710, 0x00074a }, .{ 0x00074d, 0x0007b1 }, .{ 0x0007c0, 0x0007f5 },
        .{ 0x000800, 0x00082d }, .{ 0x000840, 0x00085b }, .{ 0x000860, 0x00086a },
        .{ 0x000870, 0x000887 }, .{ 0x000889, 0x00088f }, .{ 0x000897, 0x0008e1 },
        .{ 0x0008e3, 0x000963 }, .{ 0x000966, 0x00096f }, .{ 0x000971, 0x000983 },
        .{ 0x000985, 0x00098c }, .{ 0x00098f, 0x000990 }, .{ 0x000993, 0x0009a8 },
        .{ 0x0009aa, 0x0009b0 }, .{ 0x0009b6, 0x0009b9 }, .{ 0x0009bc, 0x0009c4 },
        .{ 0x0009c7, 0x0009c8 }, .{ 0x0009cb, 0x0009ce }, .{ 0x0009dc, 0x0009dd },
        .{ 0x0009df, 0x0009e3 }, .{ 0x0009e6, 0x0009f1 }, .{ 0x000a01, 0x000a03 },
        .{ 0x000a05, 0x000a0a }, .{ 0x000a0f, 0x000a10 }, .{ 0x000a13, 0x000a28 },
        .{ 0x000a2a, 0x000a30 }, .{ 0x000a32, 0x000a33 }, .{ 0x000a35, 0x000a36 },
        .{ 0x000a38, 0x000a39 }, .{ 0x000a3e, 0x000a42 }, .{ 0x000a47, 0x000a48 },
        .{ 0x000a4b, 0x000a4d }, .{ 0x000a59, 0x000a5c }, .{ 0x000a66, 0x000a75 },
        .{ 0x000a81, 0x000a83 }, .{ 0x000a85, 0x000a8d }, .{ 0x000a8f, 0x000a91 },
        .{ 0x000a93, 0x000aa8 }, .{ 0x000aaa, 0x000ab0 }, .{ 0x000ab2, 0x000ab3 },
        .{ 0x000ab5, 0x000ab9 }, .{ 0x000abc, 0x000ac5 }, .{ 0x000ac7, 0x000ac9 },
        .{ 0x000acb, 0x000acd }, .{ 0x000ae0, 0x000ae3 }, .{ 0x000ae6, 0x000aef },
        .{ 0x000af9, 0x000aff }, .{ 0x000b01, 0x000b03 }, .{ 0x000b05, 0x000b0c },
        .{ 0x000b0f, 0x000b10 }, .{ 0x000b13, 0x000b28 }, .{ 0x000b2a, 0x000b30 },
        .{ 0x000b32, 0x000b33 }, .{ 0x000b35, 0x000b39 }, .{ 0x000b3c, 0x000b44 },
        .{ 0x000b47, 0x000b48 }, .{ 0x000b4b, 0x000b4d }, .{ 0x000b55, 0x000b57 },
        .{ 0x000b5c, 0x000b5d }, .{ 0x000b5f, 0x000b63 }, .{ 0x000b66, 0x000b6f },
        .{ 0x000b82, 0x000b83 }, .{ 0x000b85, 0x000b8a }, .{ 0x000b8e, 0x000b90 },
        .{ 0x000b92, 0x000b95 }, .{ 0x000b99, 0x000b9a }, .{ 0x000b9e, 0x000b9f },
        .{ 0x000ba3, 0x000ba4 }, .{ 0x000ba8, 0x000baa }, .{ 0x000bae, 0x000bb9 },
        .{ 0x000bbe, 0x000bc2 }, .{ 0x000bc6, 0x000bc8 }, .{ 0x000bca, 0x000bcd },
        .{ 0x000be6, 0x000bef }, .{ 0x000c00, 0x000c0c }, .{ 0x000c0e, 0x000c10 },
        .{ 0x000c12, 0x000c28 }, .{ 0x000c2a, 0x000c39 }, .{ 0x000c3c, 0x000c44 },
        .{ 0x000c46, 0x000c48 }, .{ 0x000c4a, 0x000c4d }, .{ 0x000c55, 0x000c56 },
        .{ 0x000c58, 0x000c5a }, .{ 0x000c5c, 0x000c5d }, .{ 0x000c60, 0x000c63 },
        .{ 0x000c66, 0x000c6f }, .{ 0x000c80, 0x000c83 }, .{ 0x000c85, 0x000c8c },
        .{ 0x000c8e, 0x000c90 }, .{ 0x000c92, 0x000ca8 }, .{ 0x000caa, 0x000cb3 },
        .{ 0x000cb5, 0x000cb9 }, .{ 0x000cbc, 0x000cc4 }, .{ 0x000cc6, 0x000cc8 },
        .{ 0x000cca, 0x000ccd }, .{ 0x000cd5, 0x000cd6 }, .{ 0x000cdc, 0x000cde },
        .{ 0x000ce0, 0x000ce3 }, .{ 0x000ce6, 0x000cef }, .{ 0x000cf1, 0x000cf3 },
        .{ 0x000d00, 0x000d0c }, .{ 0x000d0e, 0x000d10 }, .{ 0x000d12, 0x000d44 },
        .{ 0x000d46, 0x000d48 }, .{ 0x000d4a, 0x000d4e }, .{ 0x000d54, 0x000d57 },
        .{ 0x000d5f, 0x000d63 }, .{ 0x000d66, 0x000d6f }, .{ 0x000d7a, 0x000d7f },
        .{ 0x000d81, 0x000d83 }, .{ 0x000d85, 0x000d96 }, .{ 0x000d9a, 0x000db1 },
        .{ 0x000db3, 0x000dbb }, .{ 0x000dc0, 0x000dc6 }, .{ 0x000dcf, 0x000dd4 },
        .{ 0x000dd8, 0x000ddf }, .{ 0x000de6, 0x000def }, .{ 0x000df2, 0x000df3 },
        .{ 0x000e01, 0x000e3a }, .{ 0x000e40, 0x000e4e }, .{ 0x000e50, 0x000e59 },
        .{ 0x000e81, 0x000e82 }, .{ 0x000e86, 0x000e8a }, .{ 0x000e8c, 0x000ea3 },
        .{ 0x000ea7, 0x000ebd }, .{ 0x000ec0, 0x000ec4 }, .{ 0x000ec8, 0x000ece },
        .{ 0x000ed0, 0x000ed9 }, .{ 0x000edc, 0x000edf }, .{ 0x000f18, 0x000f19 },
        .{ 0x000f20, 0x000f29 }, .{ 0x000f3e, 0x000f47 }, .{ 0x000f49, 0x000f6c },
        .{ 0x000f71, 0x000f84 }, .{ 0x000f86, 0x000f97 }, .{ 0x000f99, 0x000fbc },
        .{ 0x001000, 0x001049 }, .{ 0x001050, 0x00109d }, .{ 0x0010a0, 0x0010c5 },
        .{ 0x0010d0, 0x0010fa }, .{ 0x0010fc, 0x001248 }, .{ 0x00124a, 0x00124d },
        .{ 0x001250, 0x001256 }, .{ 0x00125a, 0x00125d }, .{ 0x001260, 0x001288 },
        .{ 0x00128a, 0x00128d }, .{ 0x001290, 0x0012b0 }, .{ 0x0012b2, 0x0012b5 },
        .{ 0x0012b8, 0x0012be }, .{ 0x0012c2, 0x0012c5 }, .{ 0x0012c8, 0x0012d6 },
        .{ 0x0012d8, 0x001310 }, .{ 0x001312, 0x001315 }, .{ 0x001318, 0x00135a },
        .{ 0x00135d, 0x00135f }, .{ 0x001369, 0x001371 }, .{ 0x001380, 0x00138f },
        .{ 0x0013a0, 0x0013f5 }, .{ 0x0013f8, 0x0013fd }, .{ 0x001401, 0x00166c },
        .{ 0x00166f, 0x00167f }, .{ 0x001681, 0x00169a }, .{ 0x0016a0, 0x0016ea },
        .{ 0x0016ee, 0x0016f8 }, .{ 0x001700, 0x001715 }, .{ 0x00171f, 0x001734 },
        .{ 0x001740, 0x001753 }, .{ 0x001760, 0x00176c }, .{ 0x00176e, 0x001770 },
        .{ 0x001772, 0x001773 }, .{ 0x001780, 0x0017d3 }, .{ 0x0017dc, 0x0017dd },
        .{ 0x0017e0, 0x0017e9 }, .{ 0x00180b, 0x00180d }, .{ 0x00180f, 0x001819 },
        .{ 0x001820, 0x001878 }, .{ 0x001880, 0x0018aa }, .{ 0x0018b0, 0x0018f5 },
        .{ 0x001900, 0x00191e }, .{ 0x001920, 0x00192b }, .{ 0x001930, 0x00193b },
        .{ 0x001946, 0x00196d }, .{ 0x001970, 0x001974 }, .{ 0x001980, 0x0019ab },
        .{ 0x0019b0, 0x0019c9 }, .{ 0x0019d0, 0x0019da }, .{ 0x001a00, 0x001a1b },
        .{ 0x001a20, 0x001a5e }, .{ 0x001a60, 0x001a7c }, .{ 0x001a7f, 0x001a89 },
        .{ 0x001a90, 0x001a99 }, .{ 0x001ab0, 0x001abd }, .{ 0x001abf, 0x001add },
        .{ 0x001ae0, 0x001aeb }, .{ 0x001b00, 0x001b4c }, .{ 0x001b50, 0x001b59 },
        .{ 0x001b6b, 0x001b73 }, .{ 0x001b80, 0x001bf3 }, .{ 0x001c00, 0x001c37 },
        .{ 0x001c40, 0x001c49 }, .{ 0x001c4d, 0x001c7d }, .{ 0x001c80, 0x001c8a },
        .{ 0x001c90, 0x001cba }, .{ 0x001cbd, 0x001cbf }, .{ 0x001cd0, 0x001cd2 },
        .{ 0x001cd4, 0x001cfa }, .{ 0x001d00, 0x001f15 }, .{ 0x001f18, 0x001f1d },
        .{ 0x001f20, 0x001f45 }, .{ 0x001f48, 0x001f4d }, .{ 0x001f50, 0x001f57 },
        .{ 0x001f5f, 0x001f7d }, .{ 0x001f80, 0x001fb4 }, .{ 0x001fb6, 0x001fbc },
        .{ 0x001fc2, 0x001fc4 }, .{ 0x001fc6, 0x001fcc }, .{ 0x001fd0, 0x001fd3 },
        .{ 0x001fd6, 0x001fdb }, .{ 0x001fe0, 0x001fec }, .{ 0x001ff2, 0x001ff4 },
        .{ 0x001ff6, 0x001ffc }, .{ 0x00200c, 0x00200d }, .{ 0x00203f, 0x002040 },
        .{ 0x002090, 0x00209c }, .{ 0x0020d0, 0x0020dc }, .{ 0x0020e5, 0x0020f0 },
        .{ 0x00210a, 0x002113 }, .{ 0x002118, 0x00211d }, .{ 0x00212a, 0x002139 },
        .{ 0x00213c, 0x00213f }, .{ 0x002145, 0x002149 }, .{ 0x002160, 0x002188 },
        .{ 0x002c00, 0x002ce4 }, .{ 0x002ceb, 0x002cf3 }, .{ 0x002d00, 0x002d25 },
        .{ 0x002d30, 0x002d67 }, .{ 0x002d7f, 0x002d96 }, .{ 0x002da0, 0x002da6 },
        .{ 0x002da8, 0x002dae }, .{ 0x002db0, 0x002db6 }, .{ 0x002db8, 0x002dbe },
        .{ 0x002dc0, 0x002dc6 }, .{ 0x002dc8, 0x002dce }, .{ 0x002dd0, 0x002dd6 },
        .{ 0x002dd8, 0x002dde }, .{ 0x002de0, 0x002dff }, .{ 0x003005, 0x003007 },
        .{ 0x003021, 0x00302f }, .{ 0x003031, 0x003035 }, .{ 0x003038, 0x00303c },
        .{ 0x003041, 0x003096 }, .{ 0x003099, 0x00309a }, .{ 0x00309d, 0x00309f },
        .{ 0x0030a1, 0x0030ff }, .{ 0x003105, 0x00312f }, .{ 0x003131, 0x00318e },
        .{ 0x0031a0, 0x0031bf }, .{ 0x0031f0, 0x0031ff }, .{ 0x003400, 0x004dbf },
        .{ 0x004e00, 0x00a48c }, .{ 0x00a4d0, 0x00a4fd }, .{ 0x00a500, 0x00a60c },
        .{ 0x00a610, 0x00a62b }, .{ 0x00a640, 0x00a66f }, .{ 0x00a674, 0x00a67d },
        .{ 0x00a67f, 0x00a6f1 }, .{ 0x00a717, 0x00a71f }, .{ 0x00a722, 0x00a788 },
        .{ 0x00a78b, 0x00a7dc }, .{ 0x00a7f1, 0x00a827 }, .{ 0x00a840, 0x00a873 },
        .{ 0x00a880, 0x00a8c5 }, .{ 0x00a8d0, 0x00a8d9 }, .{ 0x00a8e0, 0x00a8f7 },
        .{ 0x00a8fd, 0x00a92d }, .{ 0x00a930, 0x00a953 }, .{ 0x00a960, 0x00a97c },
        .{ 0x00a980, 0x00a9c0 }, .{ 0x00a9cf, 0x00a9d9 }, .{ 0x00a9e0, 0x00a9fe },
        .{ 0x00aa00, 0x00aa36 }, .{ 0x00aa40, 0x00aa4d }, .{ 0x00aa50, 0x00aa59 },
        .{ 0x00aa60, 0x00aa76 }, .{ 0x00aa7a, 0x00aac2 }, .{ 0x00aadb, 0x00aadd },
        .{ 0x00aae0, 0x00aaef }, .{ 0x00aaf2, 0x00aaf6 }, .{ 0x00ab01, 0x00ab06 },
        .{ 0x00ab09, 0x00ab0e }, .{ 0x00ab11, 0x00ab16 }, .{ 0x00ab20, 0x00ab26 },
        .{ 0x00ab28, 0x00ab2e }, .{ 0x00ab30, 0x00ab5a }, .{ 0x00ab5c, 0x00ab69 },
        .{ 0x00ab70, 0x00abea }, .{ 0x00abec, 0x00abed }, .{ 0x00abf0, 0x00abf9 },
        .{ 0x00ac00, 0x00d7a3 }, .{ 0x00d7b0, 0x00d7c6 }, .{ 0x00d7cb, 0x00d7fb },
        .{ 0x00f900, 0x00fa6d }, .{ 0x00fa70, 0x00fad9 }, .{ 0x00fb00, 0x00fb06 },
        .{ 0x00fb13, 0x00fb17 }, .{ 0x00fb1d, 0x00fb28 }, .{ 0x00fb2a, 0x00fb36 },
        .{ 0x00fb38, 0x00fb3c }, .{ 0x00fb40, 0x00fb41 }, .{ 0x00fb43, 0x00fb44 },
        .{ 0x00fb46, 0x00fbb1 }, .{ 0x00fbd3, 0x00fc5d }, .{ 0x00fc64, 0x00fd3d },
        .{ 0x00fd50, 0x00fd8f }, .{ 0x00fd92, 0x00fdc7 }, .{ 0x00fdf0, 0x00fdf9 },
        .{ 0x00fe00, 0x00fe0f }, .{ 0x00fe20, 0x00fe2f }, .{ 0x00fe33, 0x00fe34 },
        .{ 0x00fe4d, 0x00fe4f }, .{ 0x00fe7f, 0x00fefc }, .{ 0x00ff10, 0x00ff19 },
        .{ 0x00ff21, 0x00ff3a }, .{ 0x00ff41, 0x00ff5a }, .{ 0x00ff65, 0x00ffbe },
        .{ 0x00ffc2, 0x00ffc7 }, .{ 0x00ffca, 0x00ffcf }, .{ 0x00ffd2, 0x00ffd7 },
        .{ 0x00ffda, 0x00ffdc }, .{ 0x010000, 0x01000b }, .{ 0x01000d, 0x010026 },
        .{ 0x010028, 0x01003a }, .{ 0x01003c, 0x01003d }, .{ 0x01003f, 0x01004d },
        .{ 0x010050, 0x01005d }, .{ 0x010080, 0x0100fa }, .{ 0x010140, 0x010174 },
        .{ 0x010280, 0x01029c }, .{ 0x0102a0, 0x0102d0 }, .{ 0x010300, 0x01031f },
        .{ 0x01032d, 0x01034a }, .{ 0x010350, 0x01037a }, .{ 0x010380, 0x01039d },
        .{ 0x0103a0, 0x0103c3 }, .{ 0x0103c8, 0x0103cf }, .{ 0x0103d1, 0x0103d5 },
        .{ 0x010400, 0x01049d }, .{ 0x0104a0, 0x0104a9 }, .{ 0x0104b0, 0x0104d3 },
        .{ 0x0104d8, 0x0104fb }, .{ 0x010500, 0x010527 }, .{ 0x010530, 0x010563 },
        .{ 0x010570, 0x01057a }, .{ 0x01057c, 0x01058a }, .{ 0x01058c, 0x010592 },
        .{ 0x010594, 0x010595 }, .{ 0x010597, 0x0105a1 }, .{ 0x0105a3, 0x0105b1 },
        .{ 0x0105b3, 0x0105b9 }, .{ 0x0105bb, 0x0105bc }, .{ 0x0105c0, 0x0105f3 },
        .{ 0x010600, 0x010736 }, .{ 0x010740, 0x010755 }, .{ 0x010760, 0x010767 },
        .{ 0x010780, 0x010785 }, .{ 0x010787, 0x0107b0 }, .{ 0x0107b2, 0x0107ba },
        .{ 0x010800, 0x010805 }, .{ 0x01080a, 0x010835 }, .{ 0x010837, 0x010838 },
        .{ 0x01083f, 0x010855 }, .{ 0x010860, 0x010876 }, .{ 0x010880, 0x01089e },
        .{ 0x0108e0, 0x0108f2 }, .{ 0x0108f4, 0x0108f5 }, .{ 0x010900, 0x010915 },
        .{ 0x010920, 0x010939 }, .{ 0x010940, 0x010959 }, .{ 0x010980, 0x0109b7 },
        .{ 0x0109be, 0x0109bf }, .{ 0x010a00, 0x010a03 }, .{ 0x010a05, 0x010a06 },
        .{ 0x010a0c, 0x010a13 }, .{ 0x010a15, 0x010a17 }, .{ 0x010a19, 0x010a35 },
        .{ 0x010a38, 0x010a3a }, .{ 0x010a60, 0x010a7c }, .{ 0x010a80, 0x010a9c },
        .{ 0x010ac0, 0x010ac7 }, .{ 0x010ac9, 0x010ae6 }, .{ 0x010b00, 0x010b35 },
        .{ 0x010b40, 0x010b55 }, .{ 0x010b60, 0x010b72 }, .{ 0x010b80, 0x010b91 },
        .{ 0x010c00, 0x010c48 }, .{ 0x010c80, 0x010cb2 }, .{ 0x010cc0, 0x010cf2 },
        .{ 0x010d00, 0x010d27 }, .{ 0x010d30, 0x010d39 }, .{ 0x010d40, 0x010d65 },
        .{ 0x010d69, 0x010d6d }, .{ 0x010d6f, 0x010d85 }, .{ 0x010e80, 0x010ea9 },
        .{ 0x010eab, 0x010eac }, .{ 0x010eb0, 0x010eb1 }, .{ 0x010ec2, 0x010ec7 },
        .{ 0x010efa, 0x010f1c }, .{ 0x010f30, 0x010f50 }, .{ 0x010f70, 0x010f85 },
        .{ 0x010fb0, 0x010fc4 }, .{ 0x010fe0, 0x010ff6 }, .{ 0x011000, 0x011046 },
        .{ 0x011066, 0x011075 }, .{ 0x01107f, 0x0110ba }, .{ 0x0110d0, 0x0110e8 },
        .{ 0x0110f0, 0x0110f9 }, .{ 0x011100, 0x011134 }, .{ 0x011136, 0x01113f },
        .{ 0x011144, 0x011147 }, .{ 0x011150, 0x011173 }, .{ 0x011180, 0x0111c4 },
        .{ 0x0111c9, 0x0111cc }, .{ 0x0111ce, 0x0111da }, .{ 0x011200, 0x011211 },
        .{ 0x011213, 0x011237 }, .{ 0x01123e, 0x011241 }, .{ 0x011280, 0x011286 },
        .{ 0x01128a, 0x01128d }, .{ 0x01128f, 0x01129d }, .{ 0x01129f, 0x0112a8 },
        .{ 0x0112b0, 0x0112ea }, .{ 0x0112f0, 0x0112f9 }, .{ 0x011300, 0x011303 },
        .{ 0x011305, 0x01130c }, .{ 0x01130f, 0x011310 }, .{ 0x011313, 0x011328 },
        .{ 0x01132a, 0x011330 }, .{ 0x011332, 0x011333 }, .{ 0x011335, 0x011339 },
        .{ 0x01133b, 0x011344 }, .{ 0x011347, 0x011348 }, .{ 0x01134b, 0x01134d },
        .{ 0x01135d, 0x011363 }, .{ 0x011366, 0x01136c }, .{ 0x011370, 0x011374 },
        .{ 0x011380, 0x011389 }, .{ 0x011390, 0x0113b5 }, .{ 0x0113b7, 0x0113c0 },
        .{ 0x0113c7, 0x0113ca }, .{ 0x0113cc, 0x0113d3 }, .{ 0x0113e1, 0x0113e2 },
        .{ 0x011400, 0x01144a }, .{ 0x011450, 0x011459 }, .{ 0x01145e, 0x011461 },
        .{ 0x011480, 0x0114c5 }, .{ 0x0114d0, 0x0114d9 }, .{ 0x011580, 0x0115b5 },
        .{ 0x0115b8, 0x0115c0 }, .{ 0x0115d8, 0x0115dd }, .{ 0x011600, 0x011640 },
        .{ 0x011650, 0x011659 }, .{ 0x011680, 0x0116b8 }, .{ 0x0116c0, 0x0116c9 },
        .{ 0x0116d0, 0x0116e3 }, .{ 0x011700, 0x01171a }, .{ 0x01171d, 0x01172b },
        .{ 0x011730, 0x011739 }, .{ 0x011740, 0x011746 }, .{ 0x011800, 0x01183a },
        .{ 0x0118a0, 0x0118e9 }, .{ 0x0118ff, 0x011906 }, .{ 0x01190c, 0x011913 },
        .{ 0x011915, 0x011916 }, .{ 0x011918, 0x011935 }, .{ 0x011937, 0x011938 },
        .{ 0x01193b, 0x011943 }, .{ 0x011950, 0x011959 }, .{ 0x0119a0, 0x0119a7 },
        .{ 0x0119aa, 0x0119d7 }, .{ 0x0119da, 0x0119e1 }, .{ 0x0119e3, 0x0119e4 },
        .{ 0x011a00, 0x011a3e }, .{ 0x011a50, 0x011a99 }, .{ 0x011ab0, 0x011af8 },
        .{ 0x011b60, 0x011b67 }, .{ 0x011bc0, 0x011be0 }, .{ 0x011bf0, 0x011bf9 },
        .{ 0x011c00, 0x011c08 }, .{ 0x011c0a, 0x011c36 }, .{ 0x011c38, 0x011c40 },
        .{ 0x011c50, 0x011c59 }, .{ 0x011c72, 0x011c8f }, .{ 0x011c92, 0x011ca7 },
        .{ 0x011ca9, 0x011cb6 }, .{ 0x011d00, 0x011d06 }, .{ 0x011d08, 0x011d09 },
        .{ 0x011d0b, 0x011d36 }, .{ 0x011d3c, 0x011d3d }, .{ 0x011d3f, 0x011d47 },
        .{ 0x011d50, 0x011d59 }, .{ 0x011d60, 0x011d65 }, .{ 0x011d67, 0x011d68 },
        .{ 0x011d6a, 0x011d8e }, .{ 0x011d90, 0x011d91 }, .{ 0x011d93, 0x011d98 },
        .{ 0x011da0, 0x011da9 }, .{ 0x011db0, 0x011ddb }, .{ 0x011de0, 0x011de9 },
        .{ 0x011ee0, 0x011ef6 }, .{ 0x011f00, 0x011f10 }, .{ 0x011f12, 0x011f3a },
        .{ 0x011f3e, 0x011f42 }, .{ 0x011f50, 0x011f5a }, .{ 0x012000, 0x012399 },
        .{ 0x012400, 0x01246e }, .{ 0x012480, 0x012543 }, .{ 0x012f90, 0x012ff0 },
        .{ 0x013000, 0x01342f }, .{ 0x013440, 0x013455 }, .{ 0x013460, 0x0143fa },
        .{ 0x014400, 0x014646 }, .{ 0x016100, 0x016139 }, .{ 0x016800, 0x016a38 },
        .{ 0x016a40, 0x016a5e }, .{ 0x016a60, 0x016a69 }, .{ 0x016a70, 0x016abe },
        .{ 0x016ac0, 0x016ac9 }, .{ 0x016ad0, 0x016aed }, .{ 0x016af0, 0x016af4 },
        .{ 0x016b00, 0x016b36 }, .{ 0x016b40, 0x016b43 }, .{ 0x016b50, 0x016b59 },
        .{ 0x016b63, 0x016b77 }, .{ 0x016b7d, 0x016b8f }, .{ 0x016d40, 0x016d6c },
        .{ 0x016d70, 0x016d79 }, .{ 0x016e40, 0x016e7f }, .{ 0x016ea0, 0x016eb8 },
        .{ 0x016ebb, 0x016ed3 }, .{ 0x016f00, 0x016f4a }, .{ 0x016f4f, 0x016f87 },
        .{ 0x016f8f, 0x016f9f }, .{ 0x016fe0, 0x016fe1 }, .{ 0x016fe3, 0x016fe4 },
        .{ 0x016ff0, 0x016ff6 }, .{ 0x017000, 0x018cd5 }, .{ 0x018cff, 0x018d1e },
        .{ 0x018d80, 0x018df2 }, .{ 0x01aff0, 0x01aff3 }, .{ 0x01aff5, 0x01affb },
        .{ 0x01affd, 0x01affe }, .{ 0x01b000, 0x01b122 }, .{ 0x01b150, 0x01b152 },
        .{ 0x01b164, 0x01b167 }, .{ 0x01b170, 0x01b2fb }, .{ 0x01bc00, 0x01bc6a },
        .{ 0x01bc70, 0x01bc7c }, .{ 0x01bc80, 0x01bc88 }, .{ 0x01bc90, 0x01bc99 },
        .{ 0x01bc9d, 0x01bc9e }, .{ 0x01ccf0, 0x01ccf9 }, .{ 0x01cf00, 0x01cf2d },
        .{ 0x01cf30, 0x01cf46 }, .{ 0x01d165, 0x01d169 }, .{ 0x01d16d, 0x01d172 },
        .{ 0x01d17b, 0x01d182 }, .{ 0x01d185, 0x01d18b }, .{ 0x01d1aa, 0x01d1ad },
        .{ 0x01d242, 0x01d244 }, .{ 0x01d400, 0x01d454 }, .{ 0x01d456, 0x01d49c },
        .{ 0x01d49e, 0x01d49f }, .{ 0x01d4a5, 0x01d4a6 }, .{ 0x01d4a9, 0x01d4ac },
        .{ 0x01d4ae, 0x01d4b9 }, .{ 0x01d4bd, 0x01d4c3 }, .{ 0x01d4c5, 0x01d505 },
        .{ 0x01d507, 0x01d50a }, .{ 0x01d50d, 0x01d514 }, .{ 0x01d516, 0x01d51c },
        .{ 0x01d51e, 0x01d539 }, .{ 0x01d53b, 0x01d53e }, .{ 0x01d540, 0x01d544 },
        .{ 0x01d54a, 0x01d550 }, .{ 0x01d552, 0x01d6a5 }, .{ 0x01d6a8, 0x01d6c0 },
        .{ 0x01d6c2, 0x01d6da }, .{ 0x01d6dc, 0x01d6fa }, .{ 0x01d6fc, 0x01d714 },
        .{ 0x01d716, 0x01d734 }, .{ 0x01d736, 0x01d74e }, .{ 0x01d750, 0x01d76e },
        .{ 0x01d770, 0x01d788 }, .{ 0x01d78a, 0x01d7a8 }, .{ 0x01d7aa, 0x01d7c2 },
        .{ 0x01d7c4, 0x01d7cb }, .{ 0x01d7ce, 0x01d7ff }, .{ 0x01da00, 0x01da36 },
        .{ 0x01da3b, 0x01da6c }, .{ 0x01da9b, 0x01da9f }, .{ 0x01daa1, 0x01daaf },
        .{ 0x01df00, 0x01df1e }, .{ 0x01df25, 0x01df2a }, .{ 0x01e000, 0x01e006 },
        .{ 0x01e008, 0x01e018 }, .{ 0x01e01b, 0x01e021 }, .{ 0x01e023, 0x01e024 },
        .{ 0x01e026, 0x01e02a }, .{ 0x01e030, 0x01e06d }, .{ 0x01e100, 0x01e12c },
        .{ 0x01e130, 0x01e13d }, .{ 0x01e140, 0x01e149 }, .{ 0x01e290, 0x01e2ae },
        .{ 0x01e2c0, 0x01e2f9 }, .{ 0x01e4d0, 0x01e4f9 }, .{ 0x01e5d0, 0x01e5fa },
        .{ 0x01e6c0, 0x01e6de }, .{ 0x01e6e0, 0x01e6f5 }, .{ 0x01e6fe, 0x01e6ff },
        .{ 0x01e7e0, 0x01e7e6 }, .{ 0x01e7e8, 0x01e7eb }, .{ 0x01e7ed, 0x01e7ee },
        .{ 0x01e7f0, 0x01e7fe }, .{ 0x01e800, 0x01e8c4 }, .{ 0x01e8d0, 0x01e8d6 },
        .{ 0x01e900, 0x01e94b }, .{ 0x01e950, 0x01e959 }, .{ 0x01ee00, 0x01ee03 },
        .{ 0x01ee05, 0x01ee1f }, .{ 0x01ee21, 0x01ee22 }, .{ 0x01ee29, 0x01ee32 },
        .{ 0x01ee34, 0x01ee37 }, .{ 0x01ee4d, 0x01ee4f }, .{ 0x01ee51, 0x01ee52 },
        .{ 0x01ee61, 0x01ee62 }, .{ 0x01ee67, 0x01ee6a }, .{ 0x01ee6c, 0x01ee72 },
        .{ 0x01ee74, 0x01ee77 }, .{ 0x01ee79, 0x01ee7c }, .{ 0x01ee80, 0x01ee89 },
        .{ 0x01ee8b, 0x01ee9b }, .{ 0x01eea1, 0x01eea3 }, .{ 0x01eea5, 0x01eea9 },
        .{ 0x01eeab, 0x01eebb }, .{ 0x01fbf0, 0x01fbf9 }, .{ 0x020000, 0x02a6df },
        .{ 0x02a700, 0x02b81d }, .{ 0x02b820, 0x02cead }, .{ 0x02ceb0, 0x02ebe0 },
        .{ 0x02ebf0, 0x02ee5d }, .{ 0x02f800, 0x02fa1d }, .{ 0x030000, 0x03134a },
        .{ 0x031350, 0x033479 }, .{ 0x0e0100, 0x0e01ef },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}
pub fn isUnicodeTolongSikiScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x011db0 and code_point <= 0x011ddb) or
        (code_point >= 0x011de0 and code_point <= 0x011de9);
}

pub fn isUnicodeWanchoScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x01e2ff or
        (code_point >= 0x01e2c0 and code_point <= 0x01e2f9);
}

pub fn isUnicodeWarangCitiScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0118ff or
        (code_point >= 0x0118a0 and code_point <= 0x0118f2);
}

pub fn isUnicodeZanabazarSquareScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point >= 0x011a00 and code_point <= 0x011a47;
}

pub fn isUnicodeCypriotScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x010808 or
        code_point == 0x01083c or
        code_point == 0x01083f or
        (code_point >= 0x010100 and code_point <= 0x010102) or
        (code_point >= 0x010107 and code_point <= 0x010133) or
        (code_point >= 0x010137 and code_point <= 0x01013f) or
        (code_point >= 0x010800 and code_point <= 0x010805) or
        (code_point >= 0x01080a and code_point <= 0x010835) or
        (code_point >= 0x010837 and code_point <= 0x010838);
}

pub fn isUnicodeCyrillicScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0002bc or
        code_point == 0x000304 or
        code_point == 0x000306 or
        code_point == 0x000308 or
        code_point == 0x00030b or
        code_point == 0x000311 or
        code_point == 0x001d2b or
        code_point == 0x001d78 or
        code_point == 0x001df8 or
        code_point == 0x002e43 or
        code_point == 0x01e08f or
        (code_point >= 0x000300 and code_point <= 0x000302) or
        (code_point >= 0x000400 and code_point <= 0x00052f) or
        (code_point >= 0x001c80 and code_point <= 0x001c8a) or
        (code_point >= 0x002de0 and code_point <= 0x002dff) or
        (code_point >= 0x00a640 and code_point <= 0x00a69f) or
        (code_point >= 0x00fe2e and code_point <= 0x00fe2f) or
        (code_point >= 0x01e030 and code_point <= 0x01e06d);
}

pub fn isUnicodeDevanagariScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0002bc or
        code_point == 0x0020f0 or
        (code_point >= 0x000900 and code_point <= 0x000952) or
        (code_point >= 0x000955 and code_point <= 0x00097f) or
        (code_point >= 0x001cd0 and code_point <= 0x001cf6) or
        (code_point >= 0x001cf8 and code_point <= 0x001cf9) or
        (code_point >= 0x00a830 and code_point <= 0x00a839) or
        (code_point >= 0x00a8e0 and code_point <= 0x00a8ff) or
        (code_point >= 0x011b00 and code_point <= 0x011b09);
}

pub fn isUnicodeDograScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x000964 and code_point <= 0x00096f) or
        (code_point >= 0x00a830 and code_point <= 0x00a839) or
        (code_point >= 0x011800 and code_point <= 0x01183b);
}

pub fn isUnicodeDuployanScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x00030a or
        code_point == 0x002e3c or
        (code_point >= 0x000307 and code_point <= 0x000308) or
        (code_point >= 0x000323 and code_point <= 0x000324) or
        (code_point >= 0x01bc00 and code_point <= 0x01bc6a) or
        (code_point >= 0x01bc70 and code_point <= 0x01bc7c) or
        (code_point >= 0x01bc80 and code_point <= 0x01bc88) or
        (code_point >= 0x01bc90 and code_point <= 0x01bc99) or
        (code_point >= 0x01bc9c and code_point <= 0x01bca3);
}

pub fn isUnicodeElbasanScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x000305 or
        (code_point >= 0x010500 and code_point <= 0x010527);
}

pub fn isUnicodeEthiopicScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00030e or
        code_point == 0x001258 or
        code_point == 0x0012c0 or
        (code_point >= 0x001200 and code_point <= 0x001248) or
        (code_point >= 0x00124a and code_point <= 0x00124d) or
        (code_point >= 0x001250 and code_point <= 0x001256) or
        (code_point >= 0x00125a and code_point <= 0x00125d) or
        (code_point >= 0x001260 and code_point <= 0x001288) or
        (code_point >= 0x00128a and code_point <= 0x00128d) or
        (code_point >= 0x001290 and code_point <= 0x0012b0) or
        (code_point >= 0x0012b2 and code_point <= 0x0012b5) or
        (code_point >= 0x0012b8 and code_point <= 0x0012be) or
        (code_point >= 0x0012c2 and code_point <= 0x0012c5) or
        (code_point >= 0x0012c8 and code_point <= 0x0012d6) or
        (code_point >= 0x0012d8 and code_point <= 0x001310) or
        (code_point >= 0x001312 and code_point <= 0x001315) or
        (code_point >= 0x001318 and code_point <= 0x00135a) or
        (code_point >= 0x00135d and code_point <= 0x00137c) or
        (code_point >= 0x001380 and code_point <= 0x001399) or
        (code_point >= 0x002d80 and code_point <= 0x002d96) or
        (code_point >= 0x002da0 and code_point <= 0x002da6) or
        (code_point >= 0x002da8 and code_point <= 0x002dae) or
        (code_point >= 0x002db0 and code_point <= 0x002db6) or
        (code_point >= 0x002db8 and code_point <= 0x002dbe) or
        (code_point >= 0x002dc0 and code_point <= 0x002dc6) or
        (code_point >= 0x002dc8 and code_point <= 0x002dce) or
        (code_point >= 0x002dd0 and code_point <= 0x002dd6) or
        (code_point >= 0x002dd8 and code_point <= 0x002dde) or
        (code_point >= 0x00ab01 and code_point <= 0x00ab06) or
        (code_point >= 0x00ab09 and code_point <= 0x00ab0e) or
        (code_point >= 0x00ab11 and code_point <= 0x00ab16) or
        (code_point >= 0x00ab20 and code_point <= 0x00ab26) or
        (code_point >= 0x00ab28 and code_point <= 0x00ab2e) or
        (code_point >= 0x01e7e0 and code_point <= 0x01e7e6) or
        (code_point >= 0x01e7e8 and code_point <= 0x01e7eb) or
        (code_point >= 0x01e7ed and code_point <= 0x01e7ee) or
        (code_point >= 0x01e7f0 and code_point <= 0x01e7fe);
}

pub fn isUnicodeGarayScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00060c or
        code_point == 0x00061b or
        code_point == 0x00061f or
        (code_point >= 0x010d40 and code_point <= 0x010d65) or
        (code_point >= 0x010d69 and code_point <= 0x010d85) or
        (code_point >= 0x010d8e and code_point <= 0x010d8f);
}

pub fn isUnicodeGeorgianScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x000589 or
        code_point == 0x0010c7 or
        code_point == 0x0010cd or
        code_point == 0x00205a or
        code_point == 0x002d27 or
        code_point == 0x002d2d or
        code_point == 0x002e31 or
        (code_point >= 0x0010a0 and code_point <= 0x0010c5) or
        (code_point >= 0x0010d0 and code_point <= 0x0010ff) or
        (code_point >= 0x001c90 and code_point <= 0x001cba) or
        (code_point >= 0x001cbd and code_point <= 0x001cbf) or
        (code_point >= 0x002d00 and code_point <= 0x002d25);
}

pub fn isUnicodeGlagoliticScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x000303 or
        code_point == 0x000305 or
        code_point == 0x000484 or
        code_point == 0x000487 or
        code_point == 0x000589 or
        code_point == 0x0010fb or
        code_point == 0x00205a or
        code_point == 0x002e43 or
        code_point == 0x00a66f or
        (code_point >= 0x002c00 and code_point <= 0x002c5f) or
        (code_point >= 0x01e000 and code_point <= 0x01e006) or
        (code_point >= 0x01e008 and code_point <= 0x01e018) or
        (code_point >= 0x01e01b and code_point <= 0x01e021) or
        (code_point >= 0x01e023 and code_point <= 0x01e024) or
        (code_point >= 0x01e026 and code_point <= 0x01e02a);
}

pub fn isUnicodeUgariticScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x01039f or
        (code_point >= 0x010380 and code_point <= 0x01039d);
}

pub fn isUnicodeVaiScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point >= 0x00a500 and code_point <= 0x00a62b;
}

pub fn isUnicodeVithkuqiScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x010570 and code_point <= 0x01057a) or
        (code_point >= 0x01057c and code_point <= 0x01058a) or
        (code_point >= 0x01058c and code_point <= 0x010592) or
        (code_point >= 0x010594 and code_point <= 0x010595) or
        (code_point >= 0x010597 and code_point <= 0x0105a1) or
        (code_point >= 0x0105a3 and code_point <= 0x0105b1) or
        (code_point >= 0x0105b3 and code_point <= 0x0105b9) or
        (code_point >= 0x0105bb and code_point <= 0x0105bc);
}

pub fn isUnicodeSoraSompengScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x0110d0 and code_point <= 0x0110e8) or
        (code_point >= 0x0110f0 and code_point <= 0x0110f9);
}

pub fn isUnicodeTangsaScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x016a70 and code_point <= 0x016abe) or
        (code_point >= 0x016ac0 and code_point <= 0x016ac9);
}

pub fn isUnicodeGothicScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x000308 or
        code_point == 0x000331 or
        (code_point >= 0x000304 and code_point <= 0x000305) or
        (code_point >= 0x010330 and code_point <= 0x01034a);
}

pub fn isUnicodeGranthaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x001cd0 or
        code_point == 0x0020f0 or
        code_point == 0x011350 or
        code_point == 0x011357 or
        code_point == 0x011fd3 or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000be6 and code_point <= 0x000bf3) or
        (code_point >= 0x001cd2 and code_point <= 0x001cd3) or
        (code_point >= 0x001cf2 and code_point <= 0x001cf4) or
        (code_point >= 0x001cf8 and code_point <= 0x001cf9) or
        (code_point >= 0x011300 and code_point <= 0x011303) or
        (code_point >= 0x011305 and code_point <= 0x01130c) or
        (code_point >= 0x01130f and code_point <= 0x011310) or
        (code_point >= 0x011313 and code_point <= 0x011328) or
        (code_point >= 0x01132a and code_point <= 0x011330) or
        (code_point >= 0x011332 and code_point <= 0x011333) or
        (code_point >= 0x011335 and code_point <= 0x011339) or
        (code_point >= 0x01133b and code_point <= 0x011344) or
        (code_point >= 0x011347 and code_point <= 0x011348) or
        (code_point >= 0x01134b and code_point <= 0x01134d) or
        (code_point >= 0x01135d and code_point <= 0x011363) or
        (code_point >= 0x011366 and code_point <= 0x01136c) or
        (code_point >= 0x011370 and code_point <= 0x011374) or
        (code_point >= 0x011fd0 and code_point <= 0x011fd1);
}

pub fn isUnicodeGreekScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x000304 or
        code_point == 0x000306 or
        code_point == 0x000308 or
        code_point == 0x000313 or
        code_point == 0x000342 or
        code_point == 0x000345 or
        code_point == 0x00037f or
        code_point == 0x000384 or
        code_point == 0x000386 or
        code_point == 0x00038c or
        code_point == 0x001f59 or
        code_point == 0x001f5b or
        code_point == 0x001f5d or
        code_point == 0x00205d or
        code_point == 0x002126 or
        code_point == 0x00ab65 or
        code_point == 0x0101a0 or
        (code_point >= 0x000300 and code_point <= 0x000301) or
        (code_point >= 0x000370 and code_point <= 0x000377) or
        (code_point >= 0x00037a and code_point <= 0x00037d) or
        (code_point >= 0x000388 and code_point <= 0x00038a) or
        (code_point >= 0x00038e and code_point <= 0x0003a1) or
        (code_point >= 0x0003a3 and code_point <= 0x0003e1) or
        (code_point >= 0x0003f0 and code_point <= 0x0003ff) or
        (code_point >= 0x001d26 and code_point <= 0x001d2a) or
        (code_point >= 0x001d5d and code_point <= 0x001d61) or
        (code_point >= 0x001d66 and code_point <= 0x001d6a) or
        (code_point >= 0x001dbf and code_point <= 0x001dc1) or
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

pub fn isUnicodeGujaratiScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000ad0 or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000a81 and code_point <= 0x000a83) or
        (code_point >= 0x000a85 and code_point <= 0x000a8d) or
        (code_point >= 0x000a8f and code_point <= 0x000a91) or
        (code_point >= 0x000a93 and code_point <= 0x000aa8) or
        (code_point >= 0x000aaa and code_point <= 0x000ab0) or
        (code_point >= 0x000ab2 and code_point <= 0x000ab3) or
        (code_point >= 0x000ab5 and code_point <= 0x000ab9) or
        (code_point >= 0x000abc and code_point <= 0x000ac5) or
        (code_point >= 0x000ac7 and code_point <= 0x000ac9) or
        (code_point >= 0x000acb and code_point <= 0x000acd) or
        (code_point >= 0x000ae0 and code_point <= 0x000ae3) or
        (code_point >= 0x000ae6 and code_point <= 0x000af1) or
        (code_point >= 0x000af9 and code_point <= 0x000aff) or
        (code_point >= 0x00a830 and code_point <= 0x00a839);
}

pub fn isUnicodeGunjalaGondiScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x011d60 and code_point <= 0x011d65) or
        (code_point >= 0x011d67 and code_point <= 0x011d68) or
        (code_point >= 0x011d6a and code_point <= 0x011d8e) or
        (code_point >= 0x011d90 and code_point <= 0x011d91) or
        (code_point >= 0x011d93 and code_point <= 0x011d98) or
        (code_point >= 0x011da0 and code_point <= 0x011da9);
}

pub fn isUnicodeGurmukhiScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000a3c or
        code_point == 0x000a51 or
        code_point == 0x000a5e or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000a01 and code_point <= 0x000a03) or
        (code_point >= 0x000a05 and code_point <= 0x000a0a) or
        (code_point >= 0x000a0f and code_point <= 0x000a10) or
        (code_point >= 0x000a13 and code_point <= 0x000a28) or
        (code_point >= 0x000a2a and code_point <= 0x000a30) or
        (code_point >= 0x000a32 and code_point <= 0x000a33) or
        (code_point >= 0x000a35 and code_point <= 0x000a36) or
        (code_point >= 0x000a38 and code_point <= 0x000a39) or
        (code_point >= 0x000a3e and code_point <= 0x000a42) or
        (code_point >= 0x000a47 and code_point <= 0x000a48) or
        (code_point >= 0x000a4b and code_point <= 0x000a4d) or
        (code_point >= 0x000a59 and code_point <= 0x000a5c) or
        (code_point >= 0x000a66 and code_point <= 0x000a76) or
        (code_point >= 0x00a830 and code_point <= 0x00a839);
}

pub fn isUnicodeHanScriptCodePoint(code_point: u21) bool {
    return code_point == 0x003005 or
        code_point == 0x003007 or
        (code_point >= 0x002e80 and code_point <= 0x002e99) or
        (code_point >= 0x002e9b and code_point <= 0x002ef3) or
        (code_point >= 0x002f00 and code_point <= 0x002fd5) or
        (code_point >= 0x003021 and code_point <= 0x003029) or
        (code_point >= 0x003038 and code_point <= 0x00303b) or
        (code_point >= 0x003400 and code_point <= 0x004dbf) or
        (code_point >= 0x004e00 and code_point <= 0x009fff) or
        (code_point >= 0x00f900 and code_point <= 0x00fa6d) or
        (code_point >= 0x00fa70 and code_point <= 0x00fad9) or
        (code_point >= 0x016fe2 and code_point <= 0x016fe3) or
        (code_point >= 0x016ff0 and code_point <= 0x016ff6) or
        (code_point >= 0x020000 and code_point <= 0x02a6df) or
        (code_point >= 0x02a700 and code_point <= 0x02b81d) or
        (code_point >= 0x02b820 and code_point <= 0x02cead) or
        (code_point >= 0x02ceb0 and code_point <= 0x02ebe0) or
        (code_point >= 0x02ebf0 and code_point <= 0x02ee5d) or
        (code_point >= 0x02f800 and code_point <= 0x02fa1d) or
        (code_point >= 0x030000 and code_point <= 0x03134a) or
        (code_point >= 0x031350 and code_point <= 0x033479);
}

pub fn isUnicodeHanScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x003030 or
        code_point == 0x0030fb or
        code_point == 0x0031ef or
        code_point == 0x0032ff or
        (code_point >= 0x002e80 and code_point <= 0x002e99) or
        (code_point >= 0x002e9b and code_point <= 0x002ef3) or
        (code_point >= 0x002f00 and code_point <= 0x002fd5) or
        (code_point >= 0x002ff0 and code_point <= 0x002fff) or
        (code_point >= 0x003001 and code_point <= 0x003003) or
        (code_point >= 0x003005 and code_point <= 0x003011) or
        (code_point >= 0x003013 and code_point <= 0x00301f) or
        (code_point >= 0x003021 and code_point <= 0x00302d) or
        (code_point >= 0x003037 and code_point <= 0x00303f) or
        (code_point >= 0x003190 and code_point <= 0x00319f) or
        (code_point >= 0x0031c0 and code_point <= 0x0031e5) or
        (code_point >= 0x003220 and code_point <= 0x003247) or
        (code_point >= 0x003280 and code_point <= 0x0032b0) or
        (code_point >= 0x0032c0 and code_point <= 0x0032cb) or
        (code_point >= 0x003358 and code_point <= 0x003370) or
        (code_point >= 0x00337b and code_point <= 0x00337f) or
        (code_point >= 0x0033e0 and code_point <= 0x0033fe) or
        (code_point >= 0x003400 and code_point <= 0x004dbf) or
        (code_point >= 0x004e00 and code_point <= 0x009fff) or
        (code_point >= 0x00a700 and code_point <= 0x00a707) or
        (code_point >= 0x00f900 and code_point <= 0x00fa6d) or
        (code_point >= 0x00fa70 and code_point <= 0x00fad9) or
        (code_point >= 0x00fe45 and code_point <= 0x00fe46) or
        (code_point >= 0x00ff61 and code_point <= 0x00ff65) or
        (code_point >= 0x016fe2 and code_point <= 0x016fe3) or
        (code_point >= 0x016ff0 and code_point <= 0x016ff6) or
        (code_point >= 0x01d360 and code_point <= 0x01d371) or
        (code_point >= 0x01f250 and code_point <= 0x01f251) or
        (code_point >= 0x020000 and code_point <= 0x02a6df) or
        (code_point >= 0x02a700 and code_point <= 0x02b81d) or
        (code_point >= 0x02b820 and code_point <= 0x02cead) or
        (code_point >= 0x02ceb0 and code_point <= 0x02ebe0) or
        (code_point >= 0x02ebf0 and code_point <= 0x02ee5d) or
        (code_point >= 0x02f800 and code_point <= 0x02fa1d) or
        (code_point >= 0x030000 and code_point <= 0x03134a) or
        (code_point >= 0x031350 and code_point <= 0x033479);
}

pub fn isUnicodeHangulScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x003037 or
        code_point == 0x0030fb or
        (code_point >= 0x001100 and code_point <= 0x0011ff) or
        (code_point >= 0x003001 and code_point <= 0x003003) or
        (code_point >= 0x003008 and code_point <= 0x003011) or
        (code_point >= 0x003013 and code_point <= 0x00301f) or
        (code_point >= 0x00302e and code_point <= 0x003030) or
        (code_point >= 0x003131 and code_point <= 0x00318e) or
        (code_point >= 0x003200 and code_point <= 0x00321e) or
        (code_point >= 0x003260 and code_point <= 0x00327e) or
        (code_point >= 0x00a960 and code_point <= 0x00a97c) or
        (code_point >= 0x00ac00 and code_point <= 0x00d7a3) or
        (code_point >= 0x00d7b0 and code_point <= 0x00d7c6) or
        (code_point >= 0x00d7cb and code_point <= 0x00d7fb) or
        (code_point >= 0x00fe45 and code_point <= 0x00fe46) or
        (code_point >= 0x00ff61 and code_point <= 0x00ff65) or
        (code_point >= 0x00ffa0 and code_point <= 0x00ffbe) or
        (code_point >= 0x00ffc2 and code_point <= 0x00ffc7) or
        (code_point >= 0x00ffca and code_point <= 0x00ffcf) or
        (code_point >= 0x00ffd2 and code_point <= 0x00ffd7) or
        (code_point >= 0x00ffda and code_point <= 0x00ffdc);
}

pub fn isUnicodeHanifiRohingyaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00060c or
        code_point == 0x00061b or
        code_point == 0x00061f or
        code_point == 0x000640 or
        code_point == 0x0006d4 or
        (code_point >= 0x010d00 and code_point <= 0x010d27) or
        (code_point >= 0x010d30 and code_point <= 0x010d39);
}

pub fn isUnicodeHebrewScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00fb3e or
        (code_point >= 0x000307 and code_point <= 0x000308) or
        (code_point >= 0x000591 and code_point <= 0x0005c7) or
        (code_point >= 0x0005d0 and code_point <= 0x0005ea) or
        (code_point >= 0x0005ef and code_point <= 0x0005f4) or
        (code_point >= 0x00fb1d and code_point <= 0x00fb36) or
        (code_point >= 0x00fb38 and code_point <= 0x00fb3c) or
        (code_point >= 0x00fb40 and code_point <= 0x00fb41) or
        (code_point >= 0x00fb43 and code_point <= 0x00fb44) or
        (code_point >= 0x00fb46 and code_point <= 0x00fb4f);
}

pub fn isUnicodeHiraganaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x003037 or
        code_point == 0x00ff70 or
        code_point == 0x01b132 or
        code_point == 0x01f200 or
        (code_point >= 0x003001 and code_point <= 0x003003) or
        (code_point >= 0x003008 and code_point <= 0x003011) or
        (code_point >= 0x003013 and code_point <= 0x00301f) or
        (code_point >= 0x003030 and code_point <= 0x003035) or
        (code_point >= 0x00303c and code_point <= 0x00303d) or
        (code_point >= 0x003041 and code_point <= 0x003096) or
        (code_point >= 0x003099 and code_point <= 0x0030a0) or
        (code_point >= 0x0030fb and code_point <= 0x0030fc) or
        (code_point >= 0x00fe45 and code_point <= 0x00fe46) or
        (code_point >= 0x00ff61 and code_point <= 0x00ff65) or
        (code_point >= 0x00ff9e and code_point <= 0x00ff9f) or
        (code_point >= 0x01b001 and code_point <= 0x01b11f) or
        (code_point >= 0x01b150 and code_point <= 0x01b152);
}

pub fn isUnicodeInheritedScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00030f or
        code_point == 0x000312 or
        code_point == 0x00032f or
        code_point == 0x001df9 or
        code_point == 0x0101fd or
        (code_point >= 0x000314 and code_point <= 0x000322) or
        (code_point >= 0x000326 and code_point <= 0x00032c) or
        (code_point >= 0x000332 and code_point <= 0x000341) or
        (code_point >= 0x000343 and code_point <= 0x000344) or
        (code_point >= 0x000346 and code_point <= 0x000357) or
        (code_point >= 0x000359 and code_point <= 0x00035d) or
        (code_point >= 0x00035f and code_point <= 0x000362) or
        (code_point >= 0x000953 and code_point <= 0x000954) or
        (code_point >= 0x001ab0 and code_point <= 0x001add) or
        (code_point >= 0x001ae0 and code_point <= 0x001aeb) or
        (code_point >= 0x001dc2 and code_point <= 0x001df7) or
        (code_point >= 0x001dfb and code_point <= 0x001dff) or
        (code_point >= 0x00200c and code_point <= 0x00200d) or
        (code_point >= 0x0020d0 and code_point <= 0x0020ef) or
        (code_point >= 0x00fe00 and code_point <= 0x00fe0f) or
        (code_point >= 0x00fe20 and code_point <= 0x00fe2d) or
        (code_point >= 0x01cf00 and code_point <= 0x01cf2d) or
        (code_point >= 0x01cf30 and code_point <= 0x01cf46) or
        (code_point >= 0x01d167 and code_point <= 0x01d169) or
        (code_point >= 0x01d17b and code_point <= 0x01d182) or
        (code_point >= 0x01d185 and code_point <= 0x01d18b) or
        (code_point >= 0x01d1aa and code_point <= 0x01d1ad) or
        (code_point >= 0x0e0100 and code_point <= 0x0e01ef);
}

pub fn isUnicodeJavaneseScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x00a980 and code_point <= 0x00a9cd) or
        (code_point >= 0x00a9cf and code_point <= 0x00a9d9) or
        (code_point >= 0x00a9de and code_point <= 0x00a9df);
}

pub fn isUnicodeKaithiScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x002e31 or
        code_point == 0x0110cd or
        (code_point >= 0x000966 and code_point <= 0x00096f) or
        (code_point >= 0x00a830 and code_point <= 0x00a839) or
        (code_point >= 0x011080 and code_point <= 0x0110c2);
}

pub fn isUnicodeKannadaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x001cd0 or
        code_point == 0x001cda or
        code_point == 0x001cf2 or
        code_point == 0x001cf4 or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000c80 and code_point <= 0x000c8c) or
        (code_point >= 0x000c8e and code_point <= 0x000c90) or
        (code_point >= 0x000c92 and code_point <= 0x000ca8) or
        (code_point >= 0x000caa and code_point <= 0x000cb3) or
        (code_point >= 0x000cb5 and code_point <= 0x000cb9) or
        (code_point >= 0x000cbc and code_point <= 0x000cc4) or
        (code_point >= 0x000cc6 and code_point <= 0x000cc8) or
        (code_point >= 0x000cca and code_point <= 0x000ccd) or
        (code_point >= 0x000cd5 and code_point <= 0x000cd6) or
        (code_point >= 0x000cdc and code_point <= 0x000cde) or
        (code_point >= 0x000ce0 and code_point <= 0x000ce3) or
        (code_point >= 0x000ce6 and code_point <= 0x000cef) or
        (code_point >= 0x000cf1 and code_point <= 0x000cf3) or
        (code_point >= 0x001cd2 and code_point <= 0x001cd3) or
        (code_point >= 0x00a830 and code_point <= 0x00a835);
}

pub fn isUnicodeKatakanaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000305 or
        code_point == 0x000323 or
        code_point == 0x003037 or
        code_point == 0x01b000 or
        code_point == 0x01b155 or
        (code_point >= 0x003001 and code_point <= 0x003003) or
        (code_point >= 0x003008 and code_point <= 0x003011) or
        (code_point >= 0x003013 and code_point <= 0x00301f) or
        (code_point >= 0x003030 and code_point <= 0x003035) or
        (code_point >= 0x00303c and code_point <= 0x00303d) or
        (code_point >= 0x003099 and code_point <= 0x00309c) or
        (code_point >= 0x0030a0 and code_point <= 0x0030ff) or
        (code_point >= 0x0031f0 and code_point <= 0x0031ff) or
        (code_point >= 0x0032d0 and code_point <= 0x0032fe) or
        (code_point >= 0x003300 and code_point <= 0x003357) or
        (code_point >= 0x00fe45 and code_point <= 0x00fe46) or
        (code_point >= 0x00ff61 and code_point <= 0x00ff9f) or
        (code_point >= 0x01aff0 and code_point <= 0x01aff3) or
        (code_point >= 0x01aff5 and code_point <= 0x01affb) or
        (code_point >= 0x01affd and code_point <= 0x01affe) or
        (code_point >= 0x01b120 and code_point <= 0x01b122) or
        (code_point >= 0x01b164 and code_point <= 0x01b167);
}

pub fn isUnicodeKhojkiScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x000ae6 and code_point <= 0x000aef) or
        (code_point >= 0x00a830 and code_point <= 0x00a839) or
        (code_point >= 0x011200 and code_point <= 0x011211) or
        (code_point >= 0x011213 and code_point <= 0x011241);
}

pub fn isUnicodeKhudawadiScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x00a830 and code_point <= 0x00a839) or
        (code_point >= 0x0112b0 and code_point <= 0x0112ea) or
        (code_point >= 0x0112f0 and code_point <= 0x0112f9);
}

pub fn isUnicodeLatinScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000aa or
        code_point == 0x0000b7 or
        code_point == 0x0000ba or
        code_point == 0x0002bc or
        code_point == 0x0002c7 or
        code_point == 0x0002cd or
        code_point == 0x0002d7 or
        code_point == 0x0002d9 or
        code_point == 0x000313 or
        code_point == 0x000358 or
        code_point == 0x00035e or
        code_point == 0x0010fb or
        code_point == 0x001df8 or
        code_point == 0x00202f or
        code_point == 0x002071 or
        code_point == 0x00207f or
        code_point == 0x0020f0 or
        code_point == 0x002132 or
        code_point == 0x00214e or
        code_point == 0x002e17 or
        code_point == 0x00a92e or
        (code_point >= 0x000041 and code_point <= 0x00005a) or
        (code_point >= 0x000061 and code_point <= 0x00007a) or
        (code_point >= 0x0000c0 and code_point <= 0x0000d6) or
        (code_point >= 0x0000d8 and code_point <= 0x0000f6) or
        (code_point >= 0x0000f8 and code_point <= 0x0002b8) or
        (code_point >= 0x0002c9 and code_point <= 0x0002cb) or
        (code_point >= 0x0002e0 and code_point <= 0x0002e4) or
        (code_point >= 0x000300 and code_point <= 0x00030e) or
        (code_point >= 0x000310 and code_point <= 0x000311) or
        (code_point >= 0x000323 and code_point <= 0x000325) or
        (code_point >= 0x00032d and code_point <= 0x00032e) or
        (code_point >= 0x000330 and code_point <= 0x000331) or
        (code_point >= 0x000363 and code_point <= 0x00036f) or
        (code_point >= 0x000485 and code_point <= 0x000486) or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x001d00 and code_point <= 0x001d25) or
        (code_point >= 0x001d2c and code_point <= 0x001d5c) or
        (code_point >= 0x001d62 and code_point <= 0x001d65) or
        (code_point >= 0x001d6b and code_point <= 0x001d77) or
        (code_point >= 0x001d79 and code_point <= 0x001dbe) or
        (code_point >= 0x001e00 and code_point <= 0x001eff) or
        (code_point >= 0x002090 and code_point <= 0x00209c) or
        (code_point >= 0x00212a and code_point <= 0x00212b) or
        (code_point >= 0x002160 and code_point <= 0x002188) or
        (code_point >= 0x002c60 and code_point <= 0x002c7f) or
        (code_point >= 0x00a700 and code_point <= 0x00a707) or
        (code_point >= 0x00a722 and code_point <= 0x00a787) or
        (code_point >= 0x00a78b and code_point <= 0x00a7dc) or
        (code_point >= 0x00a7f1 and code_point <= 0x00a7ff) or
        (code_point >= 0x00ab30 and code_point <= 0x00ab5a) or
        (code_point >= 0x00ab5c and code_point <= 0x00ab64) or
        (code_point >= 0x00ab66 and code_point <= 0x00ab69) or
        (code_point >= 0x00fb00 and code_point <= 0x00fb06) or
        (code_point >= 0x00ff21 and code_point <= 0x00ff3a) or
        (code_point >= 0x00ff41 and code_point <= 0x00ff5a) or
        (code_point >= 0x010780 and code_point <= 0x010785) or
        (code_point >= 0x010787 and code_point <= 0x0107b0) or
        (code_point >= 0x0107b2 and code_point <= 0x0107ba) or
        (code_point >= 0x01df00 and code_point <= 0x01df1e) or
        (code_point >= 0x01df25 and code_point <= 0x01df2a);
}

pub fn isUnicodeLimbuScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000965 or
        code_point == 0x001940 or
        (code_point >= 0x001900 and code_point <= 0x00191e) or
        (code_point >= 0x001920 and code_point <= 0x00192b) or
        (code_point >= 0x001930 and code_point <= 0x00193b) or
        (code_point >= 0x001944 and code_point <= 0x00194f);
}

pub fn isUnicodeMalayalamScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x001cda or
        code_point == 0x001cf2 or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000d00 and code_point <= 0x000d0c) or
        (code_point >= 0x000d0e and code_point <= 0x000d10) or
        (code_point >= 0x000d12 and code_point <= 0x000d44) or
        (code_point >= 0x000d46 and code_point <= 0x000d48) or
        (code_point >= 0x000d4a and code_point <= 0x000d4f) or
        (code_point >= 0x000d54 and code_point <= 0x000d63) or
        (code_point >= 0x000d66 and code_point <= 0x000d7f) or
        (code_point >= 0x00a830 and code_point <= 0x00a832);
}

pub fn isUnicodeMandaicScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000640 or
        code_point == 0x00085e or
        (code_point >= 0x000840 and code_point <= 0x00085b);
}

pub fn isUnicodeModiScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x00a830 and code_point <= 0x00a839) or
        (code_point >= 0x011600 and code_point <= 0x011644) or
        (code_point >= 0x011650 and code_point <= 0x011659);
}

pub fn isUnicodeMongolianScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00202f or
        (code_point >= 0x001800 and code_point <= 0x001819) or
        (code_point >= 0x001820 and code_point <= 0x001878) or
        (code_point >= 0x001880 and code_point <= 0x0018aa) or
        (code_point >= 0x003001 and code_point <= 0x003002) or
        (code_point >= 0x003008 and code_point <= 0x00300b) or
        (code_point >= 0x011660 and code_point <= 0x01166c);
}

pub fn isUnicodeMyanmarScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00a92e or
        (code_point >= 0x001000 and code_point <= 0x00109f) or
        (code_point >= 0x00a9e0 and code_point <= 0x00a9fe) or
        (code_point >= 0x00aa60 and code_point <= 0x00aa7f) or
        (code_point >= 0x0116d0 and code_point <= 0x0116e3);
}

pub fn isUnicodeNagMundariScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point >= 0x01e4d0 and code_point <= 0x01e4f9;
}

pub fn isUnicodeNandinagariScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000951 or
        code_point == 0x001ce9 or
        code_point == 0x001cf2 or
        code_point == 0x001cfa or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000ce6 and code_point <= 0x000cef) or
        (code_point >= 0x00a830 and code_point <= 0x00a835) or
        (code_point >= 0x0119a0 and code_point <= 0x0119a7) or
        (code_point >= 0x0119aa and code_point <= 0x0119d7) or
        (code_point >= 0x0119da and code_point <= 0x0119e4);
}

pub fn isUnicodeNewaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x001cd5 or
        code_point == 0x001ce2 or
        code_point == 0x001ce9 or
        code_point == 0x001ceb or
        code_point == 0x001ced or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x001cd7 and code_point <= 0x001cd8) or
        (code_point >= 0x011400 and code_point <= 0x01145b) or
        (code_point >= 0x01145d and code_point <= 0x011461);
}

pub fn isUnicodeNewTaiLueScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x001980 and code_point <= 0x0019ab) or
        (code_point >= 0x0019b0 and code_point <= 0x0019c9) or
        (code_point >= 0x0019d0 and code_point <= 0x0019da) or
        (code_point >= 0x0019de and code_point <= 0x0019df);
}

pub fn isUnicodeNkoScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00060c or
        code_point == 0x00061b or
        code_point == 0x00061f or
        (code_point >= 0x0007c0 and code_point <= 0x0007fa) or
        (code_point >= 0x0007fd and code_point <= 0x0007ff) or
        (code_point >= 0x00fd3e and code_point <= 0x00fd3f);
}

pub fn isUnicodeOldHungarianScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00205a or
        code_point == 0x00205d or
        code_point == 0x002e31 or
        code_point == 0x002e41 or
        (code_point >= 0x010c80 and code_point <= 0x010cb2) or
        (code_point >= 0x010cc0 and code_point <= 0x010cf2) or
        (code_point >= 0x010cfa and code_point <= 0x010cff);
}

pub fn isUnicodeOldPermicScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x000300 or
        code_point == 0x000313 or
        code_point == 0x000483 or
        (code_point >= 0x000306 and code_point <= 0x000308) or
        (code_point >= 0x010350 and code_point <= 0x01037a);
}

pub fn isUnicodeOldPersianScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x0103a0 and code_point <= 0x0103c3) or
        (code_point >= 0x0103c8 and code_point <= 0x0103d5);
}

pub fn isUnicodeOldSogdianScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point >= 0x010f00 and code_point <= 0x010f27;
}

pub fn isUnicodeOldTurkicScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00205a or
        code_point == 0x002e30 or
        (code_point >= 0x010c00 and code_point <= 0x010c48);
}

pub fn isUnicodeOldUyghurScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000640 or
        code_point == 0x010af2 or
        (code_point >= 0x010f70 and code_point <= 0x010f89);
}

pub fn isUnicodeOriyaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x001cda or
        code_point == 0x001cf2 or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000b01 and code_point <= 0x000b03) or
        (code_point >= 0x000b05 and code_point <= 0x000b0c) or
        (code_point >= 0x000b0f and code_point <= 0x000b10) or
        (code_point >= 0x000b13 and code_point <= 0x000b28) or
        (code_point >= 0x000b2a and code_point <= 0x000b30) or
        (code_point >= 0x000b32 and code_point <= 0x000b33) or
        (code_point >= 0x000b35 and code_point <= 0x000b39) or
        (code_point >= 0x000b3c and code_point <= 0x000b44) or
        (code_point >= 0x000b47 and code_point <= 0x000b48) or
        (code_point >= 0x000b4b and code_point <= 0x000b4d) or
        (code_point >= 0x000b55 and code_point <= 0x000b57) or
        (code_point >= 0x000b5c and code_point <= 0x000b5d) or
        (code_point >= 0x000b5f and code_point <= 0x000b63) or
        (code_point >= 0x000b66 and code_point <= 0x000b77);
}

pub fn isUnicodeOsageScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000301 or
        code_point == 0x000304 or
        code_point == 0x00030b or
        code_point == 0x000358 or
        (code_point >= 0x0104b0 and code_point <= 0x0104d3) or
        (code_point >= 0x0104d8 and code_point <= 0x0104fb);
}

pub fn isUnicodeOsmanyaScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x010480 and code_point <= 0x01049d) or
        (code_point >= 0x0104a0 and code_point <= 0x0104a9);
}

pub fn isUnicodePahawhHmongScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x016b00 and code_point <= 0x016b45) or
        (code_point >= 0x016b50 and code_point <= 0x016b59) or
        (code_point >= 0x016b5b and code_point <= 0x016b61) or
        (code_point >= 0x016b63 and code_point <= 0x016b77) or
        (code_point >= 0x016b7d and code_point <= 0x016b8f);
}

pub fn isUnicodePauCinHauScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point >= 0x011ac0 and code_point <= 0x011af8;
}

pub fn isUnicodePhagsPaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x001805 or
        code_point == 0x00202f or
        code_point == 0x003002 or
        (code_point >= 0x001802 and code_point <= 0x001803) or
        (code_point >= 0x00a840 and code_point <= 0x00a877);
}

pub fn isUnicodePhoenicianScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x01091f or
        (code_point >= 0x010900 and code_point <= 0x01091b);
}

pub fn isUnicodePsalterPahlaviScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000640 or
        (code_point >= 0x010b80 and code_point <= 0x010b91) or
        (code_point >= 0x010b99 and code_point <= 0x010b9c) or
        (code_point >= 0x010ba9 and code_point <= 0x010baf);
}

pub fn isUnicodeRejangScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00a95f or
        (code_point >= 0x00a930 and code_point <= 0x00a953);
}

pub fn isUnicodeRunicScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point >= 0x0016a0 and code_point <= 0x0016f8;
}

pub fn isUnicodeSamaritanScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x002e31 or
        (code_point >= 0x000800 and code_point <= 0x00082d) or
        (code_point >= 0x000830 and code_point <= 0x00083e);
}

pub fn isUnicodeSaurashtraScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x00a880 and code_point <= 0x00a8c5) or
        (code_point >= 0x00a8ce and code_point <= 0x00a8d9);
}

pub fn isUnicodeSharadaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000951 or
        code_point == 0x001cd7 or
        code_point == 0x001cd9 or
        code_point == 0x001ce0 or
        code_point == 0x001cea or
        code_point == 0x001ced or
        code_point == 0x00a838 or
        (code_point >= 0x001cdc and code_point <= 0x001cdd) or
        (code_point >= 0x00a830 and code_point <= 0x00a835) or
        (code_point >= 0x011180 and code_point <= 0x0111df) or
        (code_point >= 0x011b60 and code_point <= 0x011b67);
}

pub fn isUnicodeShavianScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        (code_point >= 0x010450 and code_point <= 0x01047f);
}

pub fn isUnicodeSiddhamScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x011580 and code_point <= 0x0115b5) or
        (code_point >= 0x0115b8 and code_point <= 0x0115dd);
}

pub fn isUnicodeSideticScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point >= 0x010940 and code_point <= 0x010959;
}

pub fn isUnicodeSinhalaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000dbd or
        code_point == 0x000dca or
        code_point == 0x000dd6 or
        code_point == 0x001cf2 or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000d81 and code_point <= 0x000d83) or
        (code_point >= 0x000d85 and code_point <= 0x000d96) or
        (code_point >= 0x000d9a and code_point <= 0x000db1) or
        (code_point >= 0x000db3 and code_point <= 0x000dbb) or
        (code_point >= 0x000dc0 and code_point <= 0x000dc6) or
        (code_point >= 0x000dcf and code_point <= 0x000dd4) or
        (code_point >= 0x000dd8 and code_point <= 0x000ddf) or
        (code_point >= 0x000de6 and code_point <= 0x000def) or
        (code_point >= 0x000df2 and code_point <= 0x000df4) or
        (code_point >= 0x0111e1 and code_point <= 0x0111f4);
}

pub fn isUnicodeSogdianScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000640 or
        (code_point >= 0x010f30 and code_point <= 0x010f59);
}

pub fn isUnicodeSoyomboScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point >= 0x011a50 and code_point <= 0x011aa2;
}

pub fn isUnicodeSundaneseScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x001b80 and code_point <= 0x001bbf) or
        (code_point >= 0x001cc0 and code_point <= 0x001cc7);
}

pub fn isUnicodeSunuwarScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000303 or
        code_point == 0x00030d or
        code_point == 0x000310 or
        code_point == 0x00032d or
        code_point == 0x000331 or
        (code_point >= 0x000300 and code_point <= 0x000301) or
        (code_point >= 0x011bc0 and code_point <= 0x011be1) or
        (code_point >= 0x011bf0 and code_point <= 0x011bf9);
}

pub fn isUnicodeSylotiNagriScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x0009e6 and code_point <= 0x0009ef) or
        (code_point >= 0x00a800 and code_point <= 0x00a82c);
}

pub fn isUnicodeSyriacScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00030a or
        code_point == 0x00060c or
        code_point == 0x00061f or
        code_point == 0x000640 or
        code_point == 0x000670 or
        code_point == 0x001df8 or
        code_point == 0x001dfa or
        (code_point >= 0x000303 and code_point <= 0x000304) or
        (code_point >= 0x000307 and code_point <= 0x000308) or
        (code_point >= 0x000323 and code_point <= 0x000325) or
        (code_point >= 0x00032d and code_point <= 0x00032e) or
        (code_point >= 0x000330 and code_point <= 0x000331) or
        (code_point >= 0x00061b and code_point <= 0x00061c) or
        (code_point >= 0x00064b and code_point <= 0x000655) or
        (code_point >= 0x000700 and code_point <= 0x00070d) or
        (code_point >= 0x00070f and code_point <= 0x00074a) or
        (code_point >= 0x00074d and code_point <= 0x00074f) or
        (code_point >= 0x000860 and code_point <= 0x00086a);
}

pub fn isUnicodeTagalogScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00171f or
        (code_point >= 0x001700 and code_point <= 0x001715) or
        (code_point >= 0x001735 and code_point <= 0x001736);
}

pub fn isUnicodeTagbanwaScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x001735 and code_point <= 0x001736) or
        (code_point >= 0x001760 and code_point <= 0x00176c) or
        (code_point >= 0x00176e and code_point <= 0x001770) or
        (code_point >= 0x001772 and code_point <= 0x001773);
}

pub fn isUnicodeTaiLeScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00030c or
        (code_point >= 0x000300 and code_point <= 0x000301) or
        (code_point >= 0x000307 and code_point <= 0x000308) or
        (code_point >= 0x001040 and code_point <= 0x001049) or
        (code_point >= 0x001950 and code_point <= 0x00196d) or
        (code_point >= 0x001970 and code_point <= 0x001974);
}

pub fn isUnicodeTakriScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x00a830 and code_point <= 0x00a839) or
        (code_point >= 0x011680 and code_point <= 0x0116b9) or
        (code_point >= 0x0116c0 and code_point <= 0x0116c9);
}

pub fn isUnicodeTangutScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0031ef or
        code_point == 0x016fe0 or
        (code_point >= 0x002ff0 and code_point <= 0x002fff) or
        (code_point >= 0x017000 and code_point <= 0x018aff) or
        (code_point >= 0x018d00 and code_point <= 0x018d1e) or
        (code_point >= 0x018d80 and code_point <= 0x018df2);
}

pub fn isUnicodeTeluguScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x001cd8 or
        code_point == 0x001cda or
        code_point == 0x001cf2 or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000c00 and code_point <= 0x000c0c) or
        (code_point >= 0x000c0e and code_point <= 0x000c10) or
        (code_point >= 0x000c12 and code_point <= 0x000c28) or
        (code_point >= 0x000c2a and code_point <= 0x000c39) or
        (code_point >= 0x000c3c and code_point <= 0x000c44) or
        (code_point >= 0x000c46 and code_point <= 0x000c48) or
        (code_point >= 0x000c4a and code_point <= 0x000c4d) or
        (code_point >= 0x000c55 and code_point <= 0x000c56) or
        (code_point >= 0x000c58 and code_point <= 0x000c5a) or
        (code_point >= 0x000c5c and code_point <= 0x000c5d) or
        (code_point >= 0x000c60 and code_point <= 0x000c63) or
        (code_point >= 0x000c66 and code_point <= 0x000c6f) or
        (code_point >= 0x000c77 and code_point <= 0x000c7f) or
        (code_point >= 0x001cd5 and code_point <= 0x001cd6);
}

pub fn isUnicodeThaanaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00060c or
        code_point == 0x00061f or
        code_point == 0x00fdf2 or
        code_point == 0x00fdfd or
        (code_point >= 0x00061b and code_point <= 0x00061c) or
        (code_point >= 0x000660 and code_point <= 0x000669) or
        (code_point >= 0x000780 and code_point <= 0x0007b1);
}

pub fn isUnicodeThaiScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0002bc or
        code_point == 0x0002d7 or
        code_point == 0x000303 or
        code_point == 0x000331 or
        (code_point >= 0x000e01 and code_point <= 0x000e3a) or
        (code_point >= 0x000e40 and code_point <= 0x000e5b);
}

pub fn isUnicodeTibetanScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x000f00 and code_point <= 0x000f47) or
        (code_point >= 0x000f49 and code_point <= 0x000f6c) or
        (code_point >= 0x000f71 and code_point <= 0x000f97) or
        (code_point >= 0x000f99 and code_point <= 0x000fbc) or
        (code_point >= 0x000fbe and code_point <= 0x000fcc) or
        (code_point >= 0x000fce and code_point <= 0x000fd4) or
        (code_point >= 0x000fd9 and code_point <= 0x000fda) or
        (code_point >= 0x003008 and code_point <= 0x00300b);
}

pub fn isUnicodeTifinaghScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000302 or
        code_point == 0x000304 or
        code_point == 0x000323 or
        code_point == 0x002d7f or
        (code_point >= 0x000306 and code_point <= 0x000309) or
        (code_point >= 0x002d30 and code_point <= 0x002d67) or
        (code_point >= 0x002d6f and code_point <= 0x002d70);
}

pub fn isUnicodeTirhutaScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x001cd5 or
        code_point == 0x001ce2 or
        code_point == 0x001cf2 or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x00a830 and code_point <= 0x00a839) or
        (code_point >= 0x011480 and code_point <= 0x0114c7) or
        (code_point >= 0x0114d0 and code_point <= 0x0114d9);
}

pub fn isUnicodeTodhriScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000301 or
        code_point == 0x000304 or
        code_point == 0x000307 or
        code_point == 0x000311 or
        code_point == 0x000313 or
        code_point == 0x00035e or
        (code_point >= 0x0105c0 and code_point <= 0x0105f3);
}

pub fn isUnicodeTotoScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0002bc or
        (code_point >= 0x01e290 and code_point <= 0x01e2ae);
}

pub fn isUnicodeTuluTigalariScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x001cf2 or
        code_point == 0x001cf4 or
        code_point == 0x00a8f1 or
        code_point == 0x01138b or
        code_point == 0x01138e or
        code_point == 0x0113c2 or
        code_point == 0x0113c5 or
        (code_point >= 0x000ce6 and code_point <= 0x000cef) or
        (code_point >= 0x00a830 and code_point <= 0x00a835) or
        (code_point >= 0x011380 and code_point <= 0x011389) or
        (code_point >= 0x011390 and code_point <= 0x0113b5) or
        (code_point >= 0x0113b7 and code_point <= 0x0113c0) or
        (code_point >= 0x0113c7 and code_point <= 0x0113ca) or
        (code_point >= 0x0113cc and code_point <= 0x0113d5) or
        (code_point >= 0x0113d7 and code_point <= 0x0113d8) or
        (code_point >= 0x0113e1 and code_point <= 0x0113e2);
}

pub fn isUnicodeTamilScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x000b9c or
        code_point == 0x000bd0 or
        code_point == 0x000bd7 or
        code_point == 0x001cda or
        code_point == 0x00a8f3 or
        code_point == 0x011301 or
        code_point == 0x011303 or
        code_point == 0x011fff or
        (code_point >= 0x000951 and code_point <= 0x000952) or
        (code_point >= 0x000964 and code_point <= 0x000965) or
        (code_point >= 0x000b82 and code_point <= 0x000b83) or
        (code_point >= 0x000b85 and code_point <= 0x000b8a) or
        (code_point >= 0x000b8e and code_point <= 0x000b90) or
        (code_point >= 0x000b92 and code_point <= 0x000b95) or
        (code_point >= 0x000b99 and code_point <= 0x000b9a) or
        (code_point >= 0x000b9e and code_point <= 0x000b9f) or
        (code_point >= 0x000ba3 and code_point <= 0x000ba4) or
        (code_point >= 0x000ba8 and code_point <= 0x000baa) or
        (code_point >= 0x000bae and code_point <= 0x000bb9) or
        (code_point >= 0x000bbe and code_point <= 0x000bc2) or
        (code_point >= 0x000bc6 and code_point <= 0x000bc8) or
        (code_point >= 0x000bca and code_point <= 0x000bcd) or
        (code_point >= 0x000be6 and code_point <= 0x000bfa) or
        (code_point >= 0x01133b and code_point <= 0x01133c) or
        (code_point >= 0x011fc0 and code_point <= 0x011ff1);
}

pub fn isUnicodeHanunooScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x001720, 0x001736 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeImperialAramaicScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010840, 0x010855 }, .{ 0x010857, 0x01085f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeKawiScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x011f00, 0x011f10 }, .{ 0x011f12, 0x011f3a }, .{ 0x011f3e, 0x011f5a },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeKayahLiScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x00a900, 0x00a92f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeLaoScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000e84, 0x000ea5, 0x000ec6,
    };
    const ranges = [_][2]u21{
        .{ 0x000e81, 0x000e82 }, .{ 0x000e86, 0x000e8a }, .{ 0x000e8c, 0x000ea3 },
        .{ 0x000ea7, 0x000ebd }, .{ 0x000ec0, 0x000ec4 }, .{ 0x000ec8, 0x000ece },
        .{ 0x000ed0, 0x000ed9 }, .{ 0x000edc, 0x000edf },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeLycianScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00205a,
    };
    const ranges = [_][2]u21{
        .{ 0x010280, 0x01029c },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMedefaidrinScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x016e40, 0x016e9a },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMeeteiMayekScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x00aae0, 0x00aaf6 }, .{ 0x00abc0, 0x00abed }, .{ 0x00abf0, 0x00abf9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMendeKikakuiScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x01e800, 0x01e8c4 }, .{ 0x01e8c7, 0x01e8d6 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMeroiticCursiveScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x0109a0, 0x0109b7 }, .{ 0x0109bc, 0x0109cf }, .{ 0x0109d2, 0x0109ff },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMeroiticHieroglyphsScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00205d,
    };
    const ranges = [_][2]u21{
        .{ 0x010980, 0x01099f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMroScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x016a40, 0x016a5e }, .{ 0x016a60, 0x016a69 }, .{ 0x016a6e, 0x016a6f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeNabataeanScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010880, 0x01089e }, .{ 0x0108a7, 0x0108af },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeNushuScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x016fe1,
    };
    const ranges = [_][2]u21{
        .{ 0x01b170, 0x01b2fb },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeLinearAScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010107, 0x010133 }, .{ 0x010600, 0x010736 }, .{ 0x010740, 0x010755 },
        .{ 0x010760, 0x010767 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeLinearBScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x010000, 0x01000b }, .{ 0x01000d, 0x010026 }, .{ 0x010028, 0x01003a },
        .{ 0x01003c, 0x01003d }, .{ 0x01003f, 0x01004d }, .{ 0x010050, 0x01005d },
        .{ 0x010080, 0x0100fa }, .{ 0x010100, 0x010102 }, .{ 0x010107, 0x010133 },
        .{ 0x010137, 0x01013f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeLisuScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0002bc, 0x0002cd, 0x011fb0,
    };
    const ranges = [_][2]u21{
        .{ 0x00300a, 0x00300b }, .{ 0x00a4d0, 0x00a4ff },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeLydianScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000b7, 0x002e31, 0x01093f,
    };
    const ranges = [_][2]u21{
        .{ 0x010920, 0x010939 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMahajaniScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000b7,
    };
    const ranges = [_][2]u21{
        .{ 0x000964, 0x00096f }, .{ 0x00a830, 0x00a839 }, .{ 0x011150, 0x011176 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeManichaeanScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000640,
    };
    const ranges = [_][2]u21{
        .{ 0x010ac0, 0x010ae6 }, .{ 0x010aeb, 0x010af6 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMasaramGondiScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x011d3a,
    };
    const ranges = [_][2]u21{
        .{ 0x000964, 0x000965 }, .{ 0x011d00, 0x011d06 }, .{ 0x011d08, 0x011d09 },
        .{ 0x011d0b, 0x011d36 }, .{ 0x011d3c, 0x011d3d }, .{ 0x011d3f, 0x011d47 },
        .{ 0x011d50, 0x011d59 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMultaniScriptExtensionsCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x011288,
    };
    const ranges = [_][2]u21{
        .{ 0x000a66, 0x000a6f }, .{ 0x011280, 0x011286 }, .{ 0x01128a, 0x01128d },
        .{ 0x01128f, 0x01129d }, .{ 0x01129f, 0x0112a9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeYezidiScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x00060c or
        code_point == 0x00061b or
        code_point == 0x00061f or
        (code_point >= 0x000660 and code_point <= 0x000669) or
        (code_point >= 0x010e80 and code_point <= 0x010ea9) or
        (code_point >= 0x010eab and code_point <= 0x010ead) or
        (code_point >= 0x010eb0 and code_point <= 0x010eb1);
}

pub fn isUnicodeYiScriptExtensionsCodePoint(code_point: u21) bool {
    return code_point == 0x0030fb or
        (code_point >= 0x003001 and code_point <= 0x003002) or
        (code_point >= 0x003008 and code_point <= 0x003011) or
        (code_point >= 0x003014 and code_point <= 0x00301b) or
        (code_point >= 0x00a000 and code_point <= 0x00a48c) or
        (code_point >= 0x00a490 and code_point <= 0x00a4c6) or
        (code_point >= 0x00ff61 and code_point <= 0x00ff65);
}

pub fn isUnicodeTaiThamScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x001a20 and code_point <= 0x001a5e) or
        (code_point >= 0x001a60 and code_point <= 0x001a7c) or
        (code_point >= 0x001a7f and code_point <= 0x001a89) or
        (code_point >= 0x001a90 and code_point <= 0x001a99) or
        (code_point >= 0x001aa0 and code_point <= 0x001aad);
}

pub fn isUnicodeTaiVietScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x00aa80 and code_point <= 0x00aac2) or
        (code_point >= 0x00aadb and code_point <= 0x00aadf);
}

pub fn isUnicodeTaiYoScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x01e6c0 and code_point <= 0x01e6de) or
        (code_point >= 0x01e6e0 and code_point <= 0x01e6f5) or
        (code_point >= 0x01e6fe and code_point <= 0x01e6ff);
}

pub fn isUnicodeSignWritingScriptExtensionsCodePoint(code_point: u21) bool {
    return (code_point >= 0x01d800 and code_point <= 0x01da8b) or
        (code_point >= 0x01da9b and code_point <= 0x01da9f) or
        (code_point >= 0x01daa1 and code_point <= 0x01daaf);
}

pub fn isUnicodeUnassignedCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00038b, 0x00038d, 0x0003a2, 0x000530, 0x000590, 0x00070e,
        0x00083f, 0x00085f, 0x000984, 0x0009a9, 0x0009b1, 0x0009de,
        0x000a04, 0x000a29, 0x000a31, 0x000a34, 0x000a37, 0x000a3d,
        0x000a5d, 0x000a84, 0x000a8e, 0x000a92, 0x000aa9, 0x000ab1,
        0x000ab4, 0x000ac6, 0x000aca, 0x000b00, 0x000b04, 0x000b29,
        0x000b31, 0x000b34, 0x000b5e, 0x000b84, 0x000b91, 0x000b9b,
        0x000b9d, 0x000bc9, 0x000c0d, 0x000c11, 0x000c29, 0x000c45,
        0x000c49, 0x000c57, 0x000c5b, 0x000c8d, 0x000c91, 0x000ca9,
        0x000cb4, 0x000cc5, 0x000cc9, 0x000cdf, 0x000cf0, 0x000d0d,
        0x000d11, 0x000d45, 0x000d49, 0x000d80, 0x000d84, 0x000db2,
        0x000dbc, 0x000dd5, 0x000dd7, 0x000e83, 0x000e85, 0x000e8b,
        0x000ea4, 0x000ea6, 0x000ec5, 0x000ec7, 0x000ecf, 0x000f48,
        0x000f98, 0x000fbd, 0x000fcd, 0x0010c6, 0x001249, 0x001257,
        0x001259, 0x001289, 0x0012b1, 0x0012bf, 0x0012c1, 0x0012d7,
        0x001311, 0x00176d, 0x001771, 0x00191f, 0x001a5f, 0x001b4d,
        0x001f58, 0x001f5a, 0x001f5c, 0x001f5e, 0x001fb5, 0x001fc5,
        0x001fdc, 0x001ff5, 0x001fff, 0x002065, 0x00208f, 0x002d26,
        0x002da7, 0x002daf, 0x002db7, 0x002dbf, 0x002dc7, 0x002dcf,
        0x002dd7, 0x002ddf, 0x002e9a, 0x003040, 0x003130, 0x00318f,
        0x00321f, 0x00a9ce, 0x00a9ff, 0x00ab27, 0x00ab2f, 0x00fb37,
        0x00fb3d, 0x00fb3f, 0x00fb42, 0x00fb45, 0x00fe53, 0x00fe67,
        0x00fe75, 0x00ff00, 0x00ffe7, 0x01000c, 0x010027, 0x01003b,
        0x01003e, 0x01018f, 0x01039e, 0x01057b, 0x01058b, 0x010593,
        0x010596, 0x0105a2, 0x0105b2, 0x0105ba, 0x010786, 0x0107b1,
        0x010809, 0x010836, 0x010856, 0x0108f3, 0x010a04, 0x010a14,
        0x010a18, 0x010e7f, 0x010eaa, 0x011135, 0x0111e0, 0x011212,
        0x011287, 0x011289, 0x01128e, 0x01129e, 0x011304, 0x011329,
        0x011331, 0x011334, 0x01133a, 0x01138a, 0x01138f, 0x0113b6,
        0x0113c1, 0x0113c6, 0x0113cb, 0x0113d6, 0x01145c, 0x011914,
        0x011917, 0x011936, 0x011c09, 0x011c37, 0x011ca8, 0x011d07,
        0x011d0a, 0x011d3b, 0x011d3e, 0x011d66, 0x011d69, 0x011d8f,
        0x011d92, 0x011f11, 0x01246f, 0x016a5f, 0x016abf, 0x016b5a,
        0x016b62, 0x01aff4, 0x01affc, 0x01afff, 0x01d455, 0x01d49d,
        0x01d4ad, 0x01d4ba, 0x01d4bc, 0x01d4c4, 0x01d506, 0x01d515,
        0x01d51d, 0x01d53a, 0x01d53f, 0x01d545, 0x01d551, 0x01daa0,
        0x01e007, 0x01e022, 0x01e025, 0x01e6df, 0x01e7e7, 0x01e7ec,
        0x01e7ef, 0x01e7ff, 0x01ee04, 0x01ee20, 0x01ee23, 0x01ee28,
        0x01ee33, 0x01ee38, 0x01ee3a, 0x01ee48, 0x01ee4a, 0x01ee4c,
        0x01ee50, 0x01ee53, 0x01ee58, 0x01ee5a, 0x01ee5c, 0x01ee5e,
        0x01ee60, 0x01ee63, 0x01ee6b, 0x01ee73, 0x01ee78, 0x01ee7d,
        0x01ee7f, 0x01ee8a, 0x01eea4, 0x01eeaa, 0x01f0c0, 0x01f0d0,
        0x01fac7, 0x01fb93,
    };
    const ranges = [_][2]u21{
        .{ 0x000378, 0x000379 }, .{ 0x000380, 0x000383 }, .{ 0x000557, 0x000558 },
        .{ 0x00058b, 0x00058c }, .{ 0x0005c8, 0x0005cf }, .{ 0x0005eb, 0x0005ee },
        .{ 0x0005f5, 0x0005ff }, .{ 0x00074b, 0x00074c }, .{ 0x0007b2, 0x0007bf },
        .{ 0x0007fb, 0x0007fc }, .{ 0x00082e, 0x00082f }, .{ 0x00085c, 0x00085d },
        .{ 0x00086b, 0x00086f }, .{ 0x000892, 0x000896 }, .{ 0x00098d, 0x00098e },
        .{ 0x000991, 0x000992 }, .{ 0x0009b3, 0x0009b5 }, .{ 0x0009ba, 0x0009bb },
        .{ 0x0009c5, 0x0009c6 }, .{ 0x0009c9, 0x0009ca }, .{ 0x0009cf, 0x0009d6 },
        .{ 0x0009d8, 0x0009db }, .{ 0x0009e4, 0x0009e5 }, .{ 0x0009ff, 0x000a00 },
        .{ 0x000a0b, 0x000a0e }, .{ 0x000a11, 0x000a12 }, .{ 0x000a3a, 0x000a3b },
        .{ 0x000a43, 0x000a46 }, .{ 0x000a49, 0x000a4a }, .{ 0x000a4e, 0x000a50 },
        .{ 0x000a52, 0x000a58 }, .{ 0x000a5f, 0x000a65 }, .{ 0x000a77, 0x000a80 },
        .{ 0x000aba, 0x000abb }, .{ 0x000ace, 0x000acf }, .{ 0x000ad1, 0x000adf },
        .{ 0x000ae4, 0x000ae5 }, .{ 0x000af2, 0x000af8 }, .{ 0x000b0d, 0x000b0e },
        .{ 0x000b11, 0x000b12 }, .{ 0x000b3a, 0x000b3b }, .{ 0x000b45, 0x000b46 },
        .{ 0x000b49, 0x000b4a }, .{ 0x000b4e, 0x000b54 }, .{ 0x000b58, 0x000b5b },
        .{ 0x000b64, 0x000b65 }, .{ 0x000b78, 0x000b81 }, .{ 0x000b8b, 0x000b8d },
        .{ 0x000b96, 0x000b98 }, .{ 0x000ba0, 0x000ba2 }, .{ 0x000ba5, 0x000ba7 },
        .{ 0x000bab, 0x000bad }, .{ 0x000bba, 0x000bbd }, .{ 0x000bc3, 0x000bc5 },
        .{ 0x000bce, 0x000bcf }, .{ 0x000bd1, 0x000bd6 }, .{ 0x000bd8, 0x000be5 },
        .{ 0x000bfb, 0x000bff }, .{ 0x000c3a, 0x000c3b }, .{ 0x000c4e, 0x000c54 },
        .{ 0x000c5e, 0x000c5f }, .{ 0x000c64, 0x000c65 }, .{ 0x000c70, 0x000c76 },
        .{ 0x000cba, 0x000cbb }, .{ 0x000cce, 0x000cd4 }, .{ 0x000cd7, 0x000cdb },
        .{ 0x000ce4, 0x000ce5 }, .{ 0x000cf4, 0x000cff }, .{ 0x000d50, 0x000d53 },
        .{ 0x000d64, 0x000d65 }, .{ 0x000d97, 0x000d99 }, .{ 0x000dbe, 0x000dbf },
        .{ 0x000dc7, 0x000dc9 }, .{ 0x000dcb, 0x000dce }, .{ 0x000de0, 0x000de5 },
        .{ 0x000df0, 0x000df1 }, .{ 0x000df5, 0x000e00 }, .{ 0x000e3b, 0x000e3e },
        .{ 0x000e5c, 0x000e80 }, .{ 0x000ebe, 0x000ebf }, .{ 0x000eda, 0x000edb },
        .{ 0x000ee0, 0x000eff }, .{ 0x000f6d, 0x000f70 }, .{ 0x000fdb, 0x000fff },
        .{ 0x0010c8, 0x0010cc }, .{ 0x0010ce, 0x0010cf }, .{ 0x00124e, 0x00124f },
        .{ 0x00125e, 0x00125f }, .{ 0x00128e, 0x00128f }, .{ 0x0012b6, 0x0012b7 },
        .{ 0x0012c6, 0x0012c7 }, .{ 0x001316, 0x001317 }, .{ 0x00135b, 0x00135c },
        .{ 0x00137d, 0x00137f }, .{ 0x00139a, 0x00139f }, .{ 0x0013f6, 0x0013f7 },
        .{ 0x0013fe, 0x0013ff }, .{ 0x00169d, 0x00169f }, .{ 0x0016f9, 0x0016ff },
        .{ 0x001716, 0x00171e }, .{ 0x001737, 0x00173f }, .{ 0x001754, 0x00175f },
        .{ 0x001774, 0x00177f }, .{ 0x0017de, 0x0017df }, .{ 0x0017ea, 0x0017ef },
        .{ 0x0017fa, 0x0017ff }, .{ 0x00181a, 0x00181f }, .{ 0x001879, 0x00187f },
        .{ 0x0018ab, 0x0018af }, .{ 0x0018f6, 0x0018ff }, .{ 0x00192c, 0x00192f },
        .{ 0x00193c, 0x00193f }, .{ 0x001941, 0x001943 }, .{ 0x00196e, 0x00196f },
        .{ 0x001975, 0x00197f }, .{ 0x0019ac, 0x0019af }, .{ 0x0019ca, 0x0019cf },
        .{ 0x0019db, 0x0019dd }, .{ 0x001a1c, 0x001a1d }, .{ 0x001a7d, 0x001a7e },
        .{ 0x001a8a, 0x001a8f }, .{ 0x001a9a, 0x001a9f }, .{ 0x001aae, 0x001aaf },
        .{ 0x001ade, 0x001adf }, .{ 0x001aec, 0x001aff }, .{ 0x001bf4, 0x001bfb },
        .{ 0x001c38, 0x001c3a }, .{ 0x001c4a, 0x001c4c }, .{ 0x001c8b, 0x001c8f },
        .{ 0x001cbb, 0x001cbc }, .{ 0x001cc8, 0x001ccf }, .{ 0x001cfb, 0x001cff },
        .{ 0x001f16, 0x001f17 }, .{ 0x001f1e, 0x001f1f }, .{ 0x001f46, 0x001f47 },
        .{ 0x001f4e, 0x001f4f }, .{ 0x001f7e, 0x001f7f }, .{ 0x001fd4, 0x001fd5 },
        .{ 0x001ff0, 0x001ff1 }, .{ 0x002072, 0x002073 }, .{ 0x00209d, 0x00209f },
        .{ 0x0020c2, 0x0020cf }, .{ 0x0020f1, 0x0020ff }, .{ 0x00218c, 0x00218f },
        .{ 0x00242a, 0x00243f }, .{ 0x00244b, 0x00245f }, .{ 0x002b74, 0x002b75 },
        .{ 0x002cf4, 0x002cf8 }, .{ 0x002d28, 0x002d2c }, .{ 0x002d2e, 0x002d2f },
        .{ 0x002d68, 0x002d6e }, .{ 0x002d71, 0x002d7e }, .{ 0x002d97, 0x002d9f },
        .{ 0x002e5e, 0x002e7f }, .{ 0x002ef4, 0x002eff }, .{ 0x002fd6, 0x002fef },
        .{ 0x003097, 0x003098 }, .{ 0x003100, 0x003104 }, .{ 0x0031e6, 0x0031ee },
        .{ 0x00a48d, 0x00a48f }, .{ 0x00a4c7, 0x00a4cf }, .{ 0x00a62c, 0x00a63f },
        .{ 0x00a6f8, 0x00a6ff }, .{ 0x00a7dd, 0x00a7f0 }, .{ 0x00a82d, 0x00a82f },
        .{ 0x00a83a, 0x00a83f }, .{ 0x00a878, 0x00a87f }, .{ 0x00a8c6, 0x00a8cd },
        .{ 0x00a8da, 0x00a8df }, .{ 0x00a954, 0x00a95e }, .{ 0x00a97d, 0x00a97f },
        .{ 0x00a9da, 0x00a9dd }, .{ 0x00aa37, 0x00aa3f }, .{ 0x00aa4e, 0x00aa4f },
        .{ 0x00aa5a, 0x00aa5b }, .{ 0x00aac3, 0x00aada }, .{ 0x00aaf7, 0x00ab00 },
        .{ 0x00ab07, 0x00ab08 }, .{ 0x00ab0f, 0x00ab10 }, .{ 0x00ab17, 0x00ab1f },
        .{ 0x00ab6c, 0x00ab6f }, .{ 0x00abee, 0x00abef }, .{ 0x00abfa, 0x00abff },
        .{ 0x00d7a4, 0x00d7af }, .{ 0x00d7c7, 0x00d7ca }, .{ 0x00d7fc, 0x00d7ff },
        .{ 0x00fa6e, 0x00fa6f }, .{ 0x00fada, 0x00faff }, .{ 0x00fb07, 0x00fb12 },
        .{ 0x00fb18, 0x00fb1c }, .{ 0x00fdd0, 0x00fdef }, .{ 0x00fe1a, 0x00fe1f },
        .{ 0x00fe6c, 0x00fe6f }, .{ 0x00fefd, 0x00fefe }, .{ 0x00ffbf, 0x00ffc1 },
        .{ 0x00ffc8, 0x00ffc9 }, .{ 0x00ffd0, 0x00ffd1 }, .{ 0x00ffd8, 0x00ffd9 },
        .{ 0x00ffdd, 0x00ffdf }, .{ 0x00ffef, 0x00fff8 }, .{ 0x00fffe, 0x00ffff },
        .{ 0x01004e, 0x01004f }, .{ 0x01005e, 0x01007f }, .{ 0x0100fb, 0x0100ff },
        .{ 0x010103, 0x010106 }, .{ 0x010134, 0x010136 }, .{ 0x01019d, 0x01019f },
        .{ 0x0101a1, 0x0101cf }, .{ 0x0101fe, 0x01027f }, .{ 0x01029d, 0x01029f },
        .{ 0x0102d1, 0x0102df }, .{ 0x0102fc, 0x0102ff }, .{ 0x010324, 0x01032c },
        .{ 0x01034b, 0x01034f }, .{ 0x01037b, 0x01037f }, .{ 0x0103c4, 0x0103c7 },
        .{ 0x0103d6, 0x0103ff }, .{ 0x01049e, 0x01049f }, .{ 0x0104aa, 0x0104af },
        .{ 0x0104d4, 0x0104d7 }, .{ 0x0104fc, 0x0104ff }, .{ 0x010528, 0x01052f },
        .{ 0x010564, 0x01056e }, .{ 0x0105bd, 0x0105bf }, .{ 0x0105f4, 0x0105ff },
        .{ 0x010737, 0x01073f }, .{ 0x010756, 0x01075f }, .{ 0x010768, 0x01077f },
        .{ 0x0107bb, 0x0107ff }, .{ 0x010806, 0x010807 }, .{ 0x010839, 0x01083b },
        .{ 0x01083d, 0x01083e }, .{ 0x01089f, 0x0108a6 }, .{ 0x0108b0, 0x0108df },
        .{ 0x0108f6, 0x0108fa }, .{ 0x01091c, 0x01091e }, .{ 0x01093a, 0x01093e },
        .{ 0x01095a, 0x01097f }, .{ 0x0109b8, 0x0109bb }, .{ 0x0109d0, 0x0109d1 },
        .{ 0x010a07, 0x010a0b }, .{ 0x010a36, 0x010a37 }, .{ 0x010a3b, 0x010a3e },
        .{ 0x010a49, 0x010a4f }, .{ 0x010a59, 0x010a5f }, .{ 0x010aa0, 0x010abf },
        .{ 0x010ae7, 0x010aea }, .{ 0x010af7, 0x010aff }, .{ 0x010b36, 0x010b38 },
        .{ 0x010b56, 0x010b57 }, .{ 0x010b73, 0x010b77 }, .{ 0x010b92, 0x010b98 },
        .{ 0x010b9d, 0x010ba8 }, .{ 0x010bb0, 0x010bff }, .{ 0x010c49, 0x010c7f },
        .{ 0x010cb3, 0x010cbf }, .{ 0x010cf3, 0x010cf9 }, .{ 0x010d28, 0x010d2f },
        .{ 0x010d3a, 0x010d3f }, .{ 0x010d66, 0x010d68 }, .{ 0x010d86, 0x010d8d },
        .{ 0x010d90, 0x010e5f }, .{ 0x010eae, 0x010eaf }, .{ 0x010eb2, 0x010ec1 },
        .{ 0x010ec8, 0x010ecf }, .{ 0x010ed9, 0x010ef9 }, .{ 0x010f28, 0x010f2f },
        .{ 0x010f5a, 0x010f6f }, .{ 0x010f8a, 0x010faf }, .{ 0x010fcc, 0x010fdf },
        .{ 0x010ff7, 0x010fff }, .{ 0x01104e, 0x011051 }, .{ 0x011076, 0x01107e },
        .{ 0x0110c3, 0x0110cc }, .{ 0x0110ce, 0x0110cf }, .{ 0x0110e9, 0x0110ef },
        .{ 0x0110fa, 0x0110ff }, .{ 0x011148, 0x01114f }, .{ 0x011177, 0x01117f },
        .{ 0x0111f5, 0x0111ff }, .{ 0x011242, 0x01127f }, .{ 0x0112aa, 0x0112af },
        .{ 0x0112eb, 0x0112ef }, .{ 0x0112fa, 0x0112ff }, .{ 0x01130d, 0x01130e },
        .{ 0x011311, 0x011312 }, .{ 0x011345, 0x011346 }, .{ 0x011349, 0x01134a },
        .{ 0x01134e, 0x01134f }, .{ 0x011351, 0x011356 }, .{ 0x011358, 0x01135c },
        .{ 0x011364, 0x011365 }, .{ 0x01136d, 0x01136f }, .{ 0x011375, 0x01137f },
        .{ 0x01138c, 0x01138d }, .{ 0x0113c3, 0x0113c4 }, .{ 0x0113d9, 0x0113e0 },
        .{ 0x0113e3, 0x0113ff }, .{ 0x011462, 0x01147f }, .{ 0x0114c8, 0x0114cf },
        .{ 0x0114da, 0x01157f }, .{ 0x0115b6, 0x0115b7 }, .{ 0x0115de, 0x0115ff },
        .{ 0x011645, 0x01164f }, .{ 0x01165a, 0x01165f }, .{ 0x01166d, 0x01167f },
        .{ 0x0116ba, 0x0116bf }, .{ 0x0116ca, 0x0116cf }, .{ 0x0116e4, 0x0116ff },
        .{ 0x01171b, 0x01171c }, .{ 0x01172c, 0x01172f }, .{ 0x011747, 0x0117ff },
        .{ 0x01183c, 0x01189f }, .{ 0x0118f3, 0x0118fe }, .{ 0x011907, 0x011908 },
        .{ 0x01190a, 0x01190b }, .{ 0x011939, 0x01193a }, .{ 0x011947, 0x01194f },
        .{ 0x01195a, 0x01199f }, .{ 0x0119a8, 0x0119a9 }, .{ 0x0119d8, 0x0119d9 },
        .{ 0x0119e5, 0x0119ff }, .{ 0x011a48, 0x011a4f }, .{ 0x011aa3, 0x011aaf },
        .{ 0x011af9, 0x011aff }, .{ 0x011b0a, 0x011b5f }, .{ 0x011b68, 0x011bbf },
        .{ 0x011be2, 0x011bef }, .{ 0x011bfa, 0x011bff }, .{ 0x011c46, 0x011c4f },
        .{ 0x011c6d, 0x011c6f }, .{ 0x011c90, 0x011c91 }, .{ 0x011cb7, 0x011cff },
        .{ 0x011d37, 0x011d39 }, .{ 0x011d48, 0x011d4f }, .{ 0x011d5a, 0x011d5f },
        .{ 0x011d99, 0x011d9f }, .{ 0x011daa, 0x011daf }, .{ 0x011ddc, 0x011ddf },
        .{ 0x011dea, 0x011edf }, .{ 0x011ef9, 0x011eff }, .{ 0x011f3b, 0x011f3d },
        .{ 0x011f5b, 0x011faf }, .{ 0x011fb1, 0x011fbf }, .{ 0x011ff2, 0x011ffe },
        .{ 0x01239a, 0x0123ff }, .{ 0x012475, 0x01247f }, .{ 0x012544, 0x012f8f },
        .{ 0x012ff3, 0x012fff }, .{ 0x013456, 0x01345f }, .{ 0x0143fb, 0x0143ff },
        .{ 0x014647, 0x0160ff }, .{ 0x01613a, 0x0167ff }, .{ 0x016a39, 0x016a3f },
        .{ 0x016a6a, 0x016a6d }, .{ 0x016aca, 0x016acf }, .{ 0x016aee, 0x016aef },
        .{ 0x016af6, 0x016aff }, .{ 0x016b46, 0x016b4f }, .{ 0x016b78, 0x016b7c },
        .{ 0x016b90, 0x016d3f }, .{ 0x016d7a, 0x016e3f }, .{ 0x016e9b, 0x016e9f },
        .{ 0x016eb9, 0x016eba }, .{ 0x016ed4, 0x016eff }, .{ 0x016f4b, 0x016f4e },
        .{ 0x016f88, 0x016f8e }, .{ 0x016fa0, 0x016fdf }, .{ 0x016fe5, 0x016fef },
        .{ 0x016ff7, 0x016fff }, .{ 0x018cd6, 0x018cfe }, .{ 0x018d1f, 0x018d7f },
        .{ 0x018df3, 0x01afef }, .{ 0x01b123, 0x01b131 }, .{ 0x01b133, 0x01b14f },
        .{ 0x01b153, 0x01b154 }, .{ 0x01b156, 0x01b163 }, .{ 0x01b168, 0x01b16f },
        .{ 0x01b2fc, 0x01bbff }, .{ 0x01bc6b, 0x01bc6f }, .{ 0x01bc7d, 0x01bc7f },
        .{ 0x01bc89, 0x01bc8f }, .{ 0x01bc9a, 0x01bc9b }, .{ 0x01bca4, 0x01cbff },
        .{ 0x01ccfd, 0x01ccff }, .{ 0x01ceb4, 0x01ceb9 }, .{ 0x01ced1, 0x01cedf },
        .{ 0x01cef1, 0x01ceff }, .{ 0x01cf2e, 0x01cf2f }, .{ 0x01cf47, 0x01cf4f },
        .{ 0x01cfc4, 0x01cfff }, .{ 0x01d0f6, 0x01d0ff }, .{ 0x01d127, 0x01d128 },
        .{ 0x01d1eb, 0x01d1ff }, .{ 0x01d246, 0x01d2bf }, .{ 0x01d2d4, 0x01d2df },
        .{ 0x01d2f4, 0x01d2ff }, .{ 0x01d357, 0x01d35f }, .{ 0x01d379, 0x01d3ff },
        .{ 0x01d4a0, 0x01d4a1 }, .{ 0x01d4a3, 0x01d4a4 }, .{ 0x01d4a7, 0x01d4a8 },
        .{ 0x01d50b, 0x01d50c }, .{ 0x01d547, 0x01d549 }, .{ 0x01d6a6, 0x01d6a7 },
        .{ 0x01d7cc, 0x01d7cd }, .{ 0x01da8c, 0x01da9a }, .{ 0x01dab0, 0x01deff },
        .{ 0x01df1f, 0x01df24 }, .{ 0x01df2b, 0x01dfff }, .{ 0x01e019, 0x01e01a },
        .{ 0x01e02b, 0x01e02f }, .{ 0x01e06e, 0x01e08e }, .{ 0x01e090, 0x01e0ff },
        .{ 0x01e12d, 0x01e12f }, .{ 0x01e13e, 0x01e13f }, .{ 0x01e14a, 0x01e14d },
        .{ 0x01e150, 0x01e28f }, .{ 0x01e2af, 0x01e2bf }, .{ 0x01e2fa, 0x01e2fe },
        .{ 0x01e300, 0x01e4cf }, .{ 0x01e4fa, 0x01e5cf }, .{ 0x01e5fb, 0x01e5fe },
        .{ 0x01e600, 0x01e6bf }, .{ 0x01e6f6, 0x01e6fd }, .{ 0x01e700, 0x01e7df },
        .{ 0x01e8c5, 0x01e8c6 }, .{ 0x01e8d7, 0x01e8ff }, .{ 0x01e94c, 0x01e94f },
        .{ 0x01e95a, 0x01e95d }, .{ 0x01e960, 0x01ec70 }, .{ 0x01ecb5, 0x01ed00 },
        .{ 0x01ed3e, 0x01edff }, .{ 0x01ee25, 0x01ee26 }, .{ 0x01ee3c, 0x01ee41 },
        .{ 0x01ee43, 0x01ee46 }, .{ 0x01ee55, 0x01ee56 }, .{ 0x01ee65, 0x01ee66 },
        .{ 0x01ee9c, 0x01eea0 }, .{ 0x01eebc, 0x01eeef }, .{ 0x01eef2, 0x01efff },
        .{ 0x01f02c, 0x01f02f }, .{ 0x01f094, 0x01f09f }, .{ 0x01f0af, 0x01f0b0 },
        .{ 0x01f0f6, 0x01f0ff }, .{ 0x01f1ae, 0x01f1e5 }, .{ 0x01f203, 0x01f20f },
        .{ 0x01f23c, 0x01f23f }, .{ 0x01f249, 0x01f24f }, .{ 0x01f252, 0x01f25f },
        .{ 0x01f266, 0x01f2ff }, .{ 0x01f6d9, 0x01f6db }, .{ 0x01f6ed, 0x01f6ef },
        .{ 0x01f6fd, 0x01f6ff }, .{ 0x01f7da, 0x01f7df }, .{ 0x01f7ec, 0x01f7ef },
        .{ 0x01f7f1, 0x01f7ff }, .{ 0x01f80c, 0x01f80f }, .{ 0x01f848, 0x01f84f },
        .{ 0x01f85a, 0x01f85f }, .{ 0x01f888, 0x01f88f }, .{ 0x01f8ae, 0x01f8af },
        .{ 0x01f8bc, 0x01f8bf }, .{ 0x01f8c2, 0x01f8cf }, .{ 0x01f8d9, 0x01f8ff },
        .{ 0x01fa58, 0x01fa5f }, .{ 0x01fa6e, 0x01fa6f }, .{ 0x01fa7d, 0x01fa7f },
        .{ 0x01fa8b, 0x01fa8d }, .{ 0x01fac9, 0x01facc }, .{ 0x01fadd, 0x01fade },
        .{ 0x01faeb, 0x01faee }, .{ 0x01faf9, 0x01faff }, .{ 0x01fbfb, 0x01ffff },
        .{ 0x02a6e0, 0x02a6ff }, .{ 0x02b81e, 0x02b81f }, .{ 0x02ceae, 0x02ceaf },
        .{ 0x02ebe1, 0x02ebef }, .{ 0x02ee5e, 0x02f7ff }, .{ 0x02fa1e, 0x02ffff },
        .{ 0x03134b, 0x03134f }, .{ 0x03347a, 0x0e0000 }, .{ 0x0e0002, 0x0e001f },
        .{ 0x0e0080, 0x0e00ff }, .{ 0x0e01f0, 0x0effff }, .{ 0x0ffffe, 0x0fffff },
        .{ 0x10fffe, 0x10ffff },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeLowercaseCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000aa, 0x0000b5, 0x0000ba, 0x000101, 0x000103, 0x000105, 0x000107, 0x000109,
        0x00010b, 0x00010d, 0x00010f, 0x000111, 0x000113, 0x000115, 0x000117, 0x000119,
        0x00011b, 0x00011d, 0x00011f, 0x000121, 0x000123, 0x000125, 0x000127, 0x000129,
        0x00012b, 0x00012d, 0x00012f, 0x000131, 0x000133, 0x000135, 0x00013a, 0x00013c,
        0x00013e, 0x000140, 0x000142, 0x000144, 0x000146, 0x00014b, 0x00014d, 0x00014f,
        0x000151, 0x000153, 0x000155, 0x000157, 0x000159, 0x00015b, 0x00015d, 0x00015f,
        0x000161, 0x000163, 0x000165, 0x000167, 0x000169, 0x00016b, 0x00016d, 0x00016f,
        0x000171, 0x000173, 0x000175, 0x000177, 0x00017a, 0x00017c, 0x000183, 0x000185,
        0x000188, 0x000192, 0x000195, 0x00019e, 0x0001a1, 0x0001a3, 0x0001a5, 0x0001a8,
        0x0001ad, 0x0001b0, 0x0001b4, 0x0001b6, 0x0001c6, 0x0001c9, 0x0001cc, 0x0001ce,
        0x0001d0, 0x0001d2, 0x0001d4, 0x0001d6, 0x0001d8, 0x0001da, 0x0001df, 0x0001e1,
        0x0001e3, 0x0001e5, 0x0001e7, 0x0001e9, 0x0001eb, 0x0001ed, 0x0001f3, 0x0001f5,
        0x0001f9, 0x0001fb, 0x0001fd, 0x0001ff, 0x000201, 0x000203, 0x000205, 0x000207,
        0x000209, 0x00020b, 0x00020d, 0x00020f, 0x000211, 0x000213, 0x000215, 0x000217,
        0x000219, 0x00021b, 0x00021d, 0x00021f, 0x000221, 0x000223, 0x000225, 0x000227,
        0x000229, 0x00022b, 0x00022d, 0x00022f, 0x000231, 0x00023c, 0x000242, 0x000247,
        0x000249, 0x00024b, 0x00024d, 0x000345, 0x000371, 0x000373, 0x000377, 0x000390,
        0x0003d9, 0x0003db, 0x0003dd, 0x0003df, 0x0003e1, 0x0003e3, 0x0003e5, 0x0003e7,
        0x0003e9, 0x0003eb, 0x0003ed, 0x0003f5, 0x0003f8, 0x000461, 0x000463, 0x000465,
        0x000467, 0x000469, 0x00046b, 0x00046d, 0x00046f, 0x000471, 0x000473, 0x000475,
        0x000477, 0x000479, 0x00047b, 0x00047d, 0x00047f, 0x000481, 0x00048b, 0x00048d,
        0x00048f, 0x000491, 0x000493, 0x000495, 0x000497, 0x000499, 0x00049b, 0x00049d,
        0x00049f, 0x0004a1, 0x0004a3, 0x0004a5, 0x0004a7, 0x0004a9, 0x0004ab, 0x0004ad,
        0x0004af, 0x0004b1, 0x0004b3, 0x0004b5, 0x0004b7, 0x0004b9, 0x0004bb, 0x0004bd,
        0x0004bf, 0x0004c2, 0x0004c4, 0x0004c6, 0x0004c8, 0x0004ca, 0x0004cc, 0x0004d1,
        0x0004d3, 0x0004d5, 0x0004d7, 0x0004d9, 0x0004db, 0x0004dd, 0x0004df, 0x0004e1,
        0x0004e3, 0x0004e5, 0x0004e7, 0x0004e9, 0x0004eb, 0x0004ed, 0x0004ef, 0x0004f1,
        0x0004f3, 0x0004f5, 0x0004f7, 0x0004f9, 0x0004fb, 0x0004fd, 0x0004ff, 0x000501,
        0x000503, 0x000505, 0x000507, 0x000509, 0x00050b, 0x00050d, 0x00050f, 0x000511,
        0x000513, 0x000515, 0x000517, 0x000519, 0x00051b, 0x00051d, 0x00051f, 0x000521,
        0x000523, 0x000525, 0x000527, 0x000529, 0x00052b, 0x00052d, 0x00052f, 0x001c8a,
        0x001e01, 0x001e03, 0x001e05, 0x001e07, 0x001e09, 0x001e0b, 0x001e0d, 0x001e0f,
        0x001e11, 0x001e13, 0x001e15, 0x001e17, 0x001e19, 0x001e1b, 0x001e1d, 0x001e1f,
        0x001e21, 0x001e23, 0x001e25, 0x001e27, 0x001e29, 0x001e2b, 0x001e2d, 0x001e2f,
        0x001e31, 0x001e33, 0x001e35, 0x001e37, 0x001e39, 0x001e3b, 0x001e3d, 0x001e3f,
        0x001e41, 0x001e43, 0x001e45, 0x001e47, 0x001e49, 0x001e4b, 0x001e4d, 0x001e4f,
        0x001e51, 0x001e53, 0x001e55, 0x001e57, 0x001e59, 0x001e5b, 0x001e5d, 0x001e5f,
        0x001e61, 0x001e63, 0x001e65, 0x001e67, 0x001e69, 0x001e6b, 0x001e6d, 0x001e6f,
        0x001e71, 0x001e73, 0x001e75, 0x001e77, 0x001e79, 0x001e7b, 0x001e7d, 0x001e7f,
        0x001e81, 0x001e83, 0x001e85, 0x001e87, 0x001e89, 0x001e8b, 0x001e8d, 0x001e8f,
        0x001e91, 0x001e93, 0x001e9f, 0x001ea1, 0x001ea3, 0x001ea5, 0x001ea7, 0x001ea9,
        0x001eab, 0x001ead, 0x001eaf, 0x001eb1, 0x001eb3, 0x001eb5, 0x001eb7, 0x001eb9,
        0x001ebb, 0x001ebd, 0x001ebf, 0x001ec1, 0x001ec3, 0x001ec5, 0x001ec7, 0x001ec9,
        0x001ecb, 0x001ecd, 0x001ecf, 0x001ed1, 0x001ed3, 0x001ed5, 0x001ed7, 0x001ed9,
        0x001edb, 0x001edd, 0x001edf, 0x001ee1, 0x001ee3, 0x001ee5, 0x001ee7, 0x001ee9,
        0x001eeb, 0x001eed, 0x001eef, 0x001ef1, 0x001ef3, 0x001ef5, 0x001ef7, 0x001ef9,
        0x001efb, 0x001efd, 0x001fbe, 0x002071, 0x00207f, 0x00210a, 0x002113, 0x00212f,
        0x002134, 0x002139, 0x00214e, 0x002184, 0x002c61, 0x002c68, 0x002c6a, 0x002c6c,
        0x002c71, 0x002c81, 0x002c83, 0x002c85, 0x002c87, 0x002c89, 0x002c8b, 0x002c8d,
        0x002c8f, 0x002c91, 0x002c93, 0x002c95, 0x002c97, 0x002c99, 0x002c9b, 0x002c9d,
        0x002c9f, 0x002ca1, 0x002ca3, 0x002ca5, 0x002ca7, 0x002ca9, 0x002cab, 0x002cad,
        0x002caf, 0x002cb1, 0x002cb3, 0x002cb5, 0x002cb7, 0x002cb9, 0x002cbb, 0x002cbd,
        0x002cbf, 0x002cc1, 0x002cc3, 0x002cc5, 0x002cc7, 0x002cc9, 0x002ccb, 0x002ccd,
        0x002ccf, 0x002cd1, 0x002cd3, 0x002cd5, 0x002cd7, 0x002cd9, 0x002cdb, 0x002cdd,
        0x002cdf, 0x002ce1, 0x002cec, 0x002cee, 0x002cf3, 0x002d27, 0x002d2d, 0x00a641,
        0x00a643, 0x00a645, 0x00a647, 0x00a649, 0x00a64b, 0x00a64d, 0x00a64f, 0x00a651,
        0x00a653, 0x00a655, 0x00a657, 0x00a659, 0x00a65b, 0x00a65d, 0x00a65f, 0x00a661,
        0x00a663, 0x00a665, 0x00a667, 0x00a669, 0x00a66b, 0x00a66d, 0x00a681, 0x00a683,
        0x00a685, 0x00a687, 0x00a689, 0x00a68b, 0x00a68d, 0x00a68f, 0x00a691, 0x00a693,
        0x00a695, 0x00a697, 0x00a699, 0x00a723, 0x00a725, 0x00a727, 0x00a729, 0x00a72b,
        0x00a72d, 0x00a733, 0x00a735, 0x00a737, 0x00a739, 0x00a73b, 0x00a73d, 0x00a73f,
        0x00a741, 0x00a743, 0x00a745, 0x00a747, 0x00a749, 0x00a74b, 0x00a74d, 0x00a74f,
        0x00a751, 0x00a753, 0x00a755, 0x00a757, 0x00a759, 0x00a75b, 0x00a75d, 0x00a75f,
        0x00a761, 0x00a763, 0x00a765, 0x00a767, 0x00a769, 0x00a76b, 0x00a76d, 0x00a77a,
        0x00a77c, 0x00a77f, 0x00a781, 0x00a783, 0x00a785, 0x00a787, 0x00a78c, 0x00a78e,
        0x00a791, 0x00a797, 0x00a799, 0x00a79b, 0x00a79d, 0x00a79f, 0x00a7a1, 0x00a7a3,
        0x00a7a5, 0x00a7a7, 0x00a7a9, 0x00a7af, 0x00a7b5, 0x00a7b7, 0x00a7b9, 0x00a7bb,
        0x00a7bd, 0x00a7bf, 0x00a7c1, 0x00a7c3, 0x00a7c8, 0x00a7ca, 0x00a7cd, 0x00a7cf,
        0x00a7d1, 0x00a7d3, 0x00a7d5, 0x00a7d7, 0x00a7d9, 0x00a7db, 0x00a7f6, 0x010780,
        0x01d4bb, 0x01d7cb,
    };
    const ranges = [_][2]u21{
        .{ 0x000061, 0x00007a }, .{ 0x0000df, 0x0000f6 }, .{ 0x0000f8, 0x0000ff },
        .{ 0x000137, 0x000138 }, .{ 0x000148, 0x000149 }, .{ 0x00017e, 0x000180 },
        .{ 0x00018c, 0x00018d }, .{ 0x000199, 0x00019b }, .{ 0x0001aa, 0x0001ab },
        .{ 0x0001b9, 0x0001ba }, .{ 0x0001bd, 0x0001bf }, .{ 0x0001dc, 0x0001dd },
        .{ 0x0001ef, 0x0001f0 }, .{ 0x000233, 0x000239 }, .{ 0x00023f, 0x000240 },
        .{ 0x00024f, 0x000293 }, .{ 0x000296, 0x0002b8 }, .{ 0x0002c0, 0x0002c1 },
        .{ 0x0002e0, 0x0002e4 }, .{ 0x00037a, 0x00037d }, .{ 0x0003ac, 0x0003ce },
        .{ 0x0003d0, 0x0003d1 }, .{ 0x0003d5, 0x0003d7 }, .{ 0x0003ef, 0x0003f3 },
        .{ 0x0003fb, 0x0003fc }, .{ 0x000430, 0x00045f }, .{ 0x0004ce, 0x0004cf },
        .{ 0x000560, 0x000588 }, .{ 0x0010d0, 0x0010fa }, .{ 0x0010fc, 0x0010ff },
        .{ 0x0013f8, 0x0013fd }, .{ 0x001c80, 0x001c88 }, .{ 0x001d00, 0x001dbf },
        .{ 0x001e95, 0x001e9d }, .{ 0x001eff, 0x001f07 }, .{ 0x001f10, 0x001f15 },
        .{ 0x001f20, 0x001f27 }, .{ 0x001f30, 0x001f37 }, .{ 0x001f40, 0x001f45 },
        .{ 0x001f50, 0x001f57 }, .{ 0x001f60, 0x001f67 }, .{ 0x001f70, 0x001f7d },
        .{ 0x001f80, 0x001f87 }, .{ 0x001f90, 0x001f97 }, .{ 0x001fa0, 0x001fa7 },
        .{ 0x001fb0, 0x001fb4 }, .{ 0x001fb6, 0x001fb7 }, .{ 0x001fc2, 0x001fc4 },
        .{ 0x001fc6, 0x001fc7 }, .{ 0x001fd0, 0x001fd3 }, .{ 0x001fd6, 0x001fd7 },
        .{ 0x001fe0, 0x001fe7 }, .{ 0x001ff2, 0x001ff4 }, .{ 0x001ff6, 0x001ff7 },
        .{ 0x002090, 0x00209c }, .{ 0x00210e, 0x00210f }, .{ 0x00213c, 0x00213d },
        .{ 0x002146, 0x002149 }, .{ 0x002170, 0x00217f }, .{ 0x0024d0, 0x0024e9 },
        .{ 0x002c30, 0x002c5f }, .{ 0x002c65, 0x002c66 }, .{ 0x002c73, 0x002c74 },
        .{ 0x002c76, 0x002c7d }, .{ 0x002ce3, 0x002ce4 }, .{ 0x002d00, 0x002d25 },
        .{ 0x00a69b, 0x00a69d }, .{ 0x00a72f, 0x00a731 }, .{ 0x00a76f, 0x00a778 },
        .{ 0x00a793, 0x00a795 }, .{ 0x00a7f1, 0x00a7f4 }, .{ 0x00a7f8, 0x00a7fa },
        .{ 0x00ab30, 0x00ab5a }, .{ 0x00ab5c, 0x00ab69 }, .{ 0x00ab70, 0x00abbf },
        .{ 0x00fb00, 0x00fb06 }, .{ 0x00fb13, 0x00fb17 }, .{ 0x00ff41, 0x00ff5a },
        .{ 0x010428, 0x01044f }, .{ 0x0104d8, 0x0104fb }, .{ 0x010597, 0x0105a1 },
        .{ 0x0105a3, 0x0105b1 }, .{ 0x0105b3, 0x0105b9 }, .{ 0x0105bb, 0x0105bc },
        .{ 0x010783, 0x010785 }, .{ 0x010787, 0x0107b0 }, .{ 0x0107b2, 0x0107ba },
        .{ 0x010cc0, 0x010cf2 }, .{ 0x010d70, 0x010d85 }, .{ 0x0118c0, 0x0118df },
        .{ 0x016e60, 0x016e7f }, .{ 0x016ebb, 0x016ed3 }, .{ 0x01d41a, 0x01d433 },
        .{ 0x01d44e, 0x01d454 }, .{ 0x01d456, 0x01d467 }, .{ 0x01d482, 0x01d49b },
        .{ 0x01d4b6, 0x01d4b9 }, .{ 0x01d4bd, 0x01d4c3 }, .{ 0x01d4c5, 0x01d4cf },
        .{ 0x01d4ea, 0x01d503 }, .{ 0x01d51e, 0x01d537 }, .{ 0x01d552, 0x01d56b },
        .{ 0x01d586, 0x01d59f }, .{ 0x01d5ba, 0x01d5d3 }, .{ 0x01d5ee, 0x01d607 },
        .{ 0x01d622, 0x01d63b }, .{ 0x01d656, 0x01d66f }, .{ 0x01d68a, 0x01d6a5 },
        .{ 0x01d6c2, 0x01d6da }, .{ 0x01d6dc, 0x01d6e1 }, .{ 0x01d6fc, 0x01d714 },
        .{ 0x01d716, 0x01d71b }, .{ 0x01d736, 0x01d74e }, .{ 0x01d750, 0x01d755 },
        .{ 0x01d770, 0x01d788 }, .{ 0x01d78a, 0x01d78f }, .{ 0x01d7aa, 0x01d7c2 },
        .{ 0x01d7c4, 0x01d7c9 }, .{ 0x01df00, 0x01df09 }, .{ 0x01df0b, 0x01df1e },
        .{ 0x01df25, 0x01df2a }, .{ 0x01e030, 0x01e06d }, .{ 0x01e922, 0x01e943 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeUppercaseCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000100, 0x000102, 0x000104, 0x000106, 0x000108, 0x00010a, 0x00010c, 0x00010e,
        0x000110, 0x000112, 0x000114, 0x000116, 0x000118, 0x00011a, 0x00011c, 0x00011e,
        0x000120, 0x000122, 0x000124, 0x000126, 0x000128, 0x00012a, 0x00012c, 0x00012e,
        0x000130, 0x000132, 0x000134, 0x000136, 0x000139, 0x00013b, 0x00013d, 0x00013f,
        0x000141, 0x000143, 0x000145, 0x000147, 0x00014a, 0x00014c, 0x00014e, 0x000150,
        0x000152, 0x000154, 0x000156, 0x000158, 0x00015a, 0x00015c, 0x00015e, 0x000160,
        0x000162, 0x000164, 0x000166, 0x000168, 0x00016a, 0x00016c, 0x00016e, 0x000170,
        0x000172, 0x000174, 0x000176, 0x00017b, 0x00017d, 0x000184, 0x0001a2, 0x0001a4,
        0x0001a9, 0x0001ac, 0x0001b5, 0x0001bc, 0x0001c4, 0x0001c7, 0x0001ca, 0x0001cd,
        0x0001cf, 0x0001d1, 0x0001d3, 0x0001d5, 0x0001d7, 0x0001d9, 0x0001db, 0x0001de,
        0x0001e0, 0x0001e2, 0x0001e4, 0x0001e6, 0x0001e8, 0x0001ea, 0x0001ec, 0x0001ee,
        0x0001f1, 0x0001f4, 0x0001fa, 0x0001fc, 0x0001fe, 0x000200, 0x000202, 0x000204,
        0x000206, 0x000208, 0x00020a, 0x00020c, 0x00020e, 0x000210, 0x000212, 0x000214,
        0x000216, 0x000218, 0x00021a, 0x00021c, 0x00021e, 0x000220, 0x000222, 0x000224,
        0x000226, 0x000228, 0x00022a, 0x00022c, 0x00022e, 0x000230, 0x000232, 0x000241,
        0x000248, 0x00024a, 0x00024c, 0x00024e, 0x000370, 0x000372, 0x000376, 0x00037f,
        0x000386, 0x00038c, 0x0003cf, 0x0003d8, 0x0003da, 0x0003dc, 0x0003de, 0x0003e0,
        0x0003e2, 0x0003e4, 0x0003e6, 0x0003e8, 0x0003ea, 0x0003ec, 0x0003ee, 0x0003f4,
        0x0003f7, 0x000460, 0x000462, 0x000464, 0x000466, 0x000468, 0x00046a, 0x00046c,
        0x00046e, 0x000470, 0x000472, 0x000474, 0x000476, 0x000478, 0x00047a, 0x00047c,
        0x00047e, 0x000480, 0x00048a, 0x00048c, 0x00048e, 0x000490, 0x000492, 0x000494,
        0x000496, 0x000498, 0x00049a, 0x00049c, 0x00049e, 0x0004a0, 0x0004a2, 0x0004a4,
        0x0004a6, 0x0004a8, 0x0004aa, 0x0004ac, 0x0004ae, 0x0004b0, 0x0004b2, 0x0004b4,
        0x0004b6, 0x0004b8, 0x0004ba, 0x0004bc, 0x0004be, 0x0004c3, 0x0004c5, 0x0004c7,
        0x0004c9, 0x0004cb, 0x0004cd, 0x0004d0, 0x0004d2, 0x0004d4, 0x0004d6, 0x0004d8,
        0x0004da, 0x0004dc, 0x0004de, 0x0004e0, 0x0004e2, 0x0004e4, 0x0004e6, 0x0004e8,
        0x0004ea, 0x0004ec, 0x0004ee, 0x0004f0, 0x0004f2, 0x0004f4, 0x0004f6, 0x0004f8,
        0x0004fa, 0x0004fc, 0x0004fe, 0x000500, 0x000502, 0x000504, 0x000506, 0x000508,
        0x00050a, 0x00050c, 0x00050e, 0x000510, 0x000512, 0x000514, 0x000516, 0x000518,
        0x00051a, 0x00051c, 0x00051e, 0x000520, 0x000522, 0x000524, 0x000526, 0x000528,
        0x00052a, 0x00052c, 0x00052e, 0x0010c7, 0x0010cd, 0x001c89, 0x001e00, 0x001e02,
        0x001e04, 0x001e06, 0x001e08, 0x001e0a, 0x001e0c, 0x001e0e, 0x001e10, 0x001e12,
        0x001e14, 0x001e16, 0x001e18, 0x001e1a, 0x001e1c, 0x001e1e, 0x001e20, 0x001e22,
        0x001e24, 0x001e26, 0x001e28, 0x001e2a, 0x001e2c, 0x001e2e, 0x001e30, 0x001e32,
        0x001e34, 0x001e36, 0x001e38, 0x001e3a, 0x001e3c, 0x001e3e, 0x001e40, 0x001e42,
        0x001e44, 0x001e46, 0x001e48, 0x001e4a, 0x001e4c, 0x001e4e, 0x001e50, 0x001e52,
        0x001e54, 0x001e56, 0x001e58, 0x001e5a, 0x001e5c, 0x001e5e, 0x001e60, 0x001e62,
        0x001e64, 0x001e66, 0x001e68, 0x001e6a, 0x001e6c, 0x001e6e, 0x001e70, 0x001e72,
        0x001e74, 0x001e76, 0x001e78, 0x001e7a, 0x001e7c, 0x001e7e, 0x001e80, 0x001e82,
        0x001e84, 0x001e86, 0x001e88, 0x001e8a, 0x001e8c, 0x001e8e, 0x001e90, 0x001e92,
        0x001e94, 0x001e9e, 0x001ea0, 0x001ea2, 0x001ea4, 0x001ea6, 0x001ea8, 0x001eaa,
        0x001eac, 0x001eae, 0x001eb0, 0x001eb2, 0x001eb4, 0x001eb6, 0x001eb8, 0x001eba,
        0x001ebc, 0x001ebe, 0x001ec0, 0x001ec2, 0x001ec4, 0x001ec6, 0x001ec8, 0x001eca,
        0x001ecc, 0x001ece, 0x001ed0, 0x001ed2, 0x001ed4, 0x001ed6, 0x001ed8, 0x001eda,
        0x001edc, 0x001ede, 0x001ee0, 0x001ee2, 0x001ee4, 0x001ee6, 0x001ee8, 0x001eea,
        0x001eec, 0x001eee, 0x001ef0, 0x001ef2, 0x001ef4, 0x001ef6, 0x001ef8, 0x001efa,
        0x001efc, 0x001efe, 0x001f59, 0x001f5b, 0x001f5d, 0x001f5f, 0x002102, 0x002107,
        0x002115, 0x002124, 0x002126, 0x002128, 0x002145, 0x002183, 0x002c60, 0x002c67,
        0x002c69, 0x002c6b, 0x002c72, 0x002c75, 0x002c82, 0x002c84, 0x002c86, 0x002c88,
        0x002c8a, 0x002c8c, 0x002c8e, 0x002c90, 0x002c92, 0x002c94, 0x002c96, 0x002c98,
        0x002c9a, 0x002c9c, 0x002c9e, 0x002ca0, 0x002ca2, 0x002ca4, 0x002ca6, 0x002ca8,
        0x002caa, 0x002cac, 0x002cae, 0x002cb0, 0x002cb2, 0x002cb4, 0x002cb6, 0x002cb8,
        0x002cba, 0x002cbc, 0x002cbe, 0x002cc0, 0x002cc2, 0x002cc4, 0x002cc6, 0x002cc8,
        0x002cca, 0x002ccc, 0x002cce, 0x002cd0, 0x002cd2, 0x002cd4, 0x002cd6, 0x002cd8,
        0x002cda, 0x002cdc, 0x002cde, 0x002ce0, 0x002ce2, 0x002ceb, 0x002ced, 0x002cf2,
        0x00a640, 0x00a642, 0x00a644, 0x00a646, 0x00a648, 0x00a64a, 0x00a64c, 0x00a64e,
        0x00a650, 0x00a652, 0x00a654, 0x00a656, 0x00a658, 0x00a65a, 0x00a65c, 0x00a65e,
        0x00a660, 0x00a662, 0x00a664, 0x00a666, 0x00a668, 0x00a66a, 0x00a66c, 0x00a680,
        0x00a682, 0x00a684, 0x00a686, 0x00a688, 0x00a68a, 0x00a68c, 0x00a68e, 0x00a690,
        0x00a692, 0x00a694, 0x00a696, 0x00a698, 0x00a69a, 0x00a722, 0x00a724, 0x00a726,
        0x00a728, 0x00a72a, 0x00a72c, 0x00a72e, 0x00a732, 0x00a734, 0x00a736, 0x00a738,
        0x00a73a, 0x00a73c, 0x00a73e, 0x00a740, 0x00a742, 0x00a744, 0x00a746, 0x00a748,
        0x00a74a, 0x00a74c, 0x00a74e, 0x00a750, 0x00a752, 0x00a754, 0x00a756, 0x00a758,
        0x00a75a, 0x00a75c, 0x00a75e, 0x00a760, 0x00a762, 0x00a764, 0x00a766, 0x00a768,
        0x00a76a, 0x00a76c, 0x00a76e, 0x00a779, 0x00a77b, 0x00a780, 0x00a782, 0x00a784,
        0x00a786, 0x00a78b, 0x00a78d, 0x00a790, 0x00a792, 0x00a796, 0x00a798, 0x00a79a,
        0x00a79c, 0x00a79e, 0x00a7a0, 0x00a7a2, 0x00a7a4, 0x00a7a6, 0x00a7a8, 0x00a7b6,
        0x00a7b8, 0x00a7ba, 0x00a7bc, 0x00a7be, 0x00a7c0, 0x00a7c2, 0x00a7c9, 0x00a7ce,
        0x00a7d0, 0x00a7d2, 0x00a7d4, 0x00a7d6, 0x00a7d8, 0x00a7da, 0x00a7dc, 0x00a7f5,
        0x01d49c, 0x01d4a2, 0x01d546, 0x01d7ca,
    };
    const ranges = [_][2]u21{
        .{ 0x000041, 0x00005a }, .{ 0x0000c0, 0x0000d6 }, .{ 0x0000d8, 0x0000de },
        .{ 0x000178, 0x000179 }, .{ 0x000181, 0x000182 }, .{ 0x000186, 0x000187 },
        .{ 0x000189, 0x00018b }, .{ 0x00018e, 0x000191 }, .{ 0x000193, 0x000194 },
        .{ 0x000196, 0x000198 }, .{ 0x00019c, 0x00019d }, .{ 0x00019f, 0x0001a0 },
        .{ 0x0001a6, 0x0001a7 }, .{ 0x0001ae, 0x0001af }, .{ 0x0001b1, 0x0001b3 },
        .{ 0x0001b7, 0x0001b8 }, .{ 0x0001f6, 0x0001f8 }, .{ 0x00023a, 0x00023b },
        .{ 0x00023d, 0x00023e }, .{ 0x000243, 0x000246 }, .{ 0x000388, 0x00038a },
        .{ 0x00038e, 0x00038f }, .{ 0x000391, 0x0003a1 }, .{ 0x0003a3, 0x0003ab },
        .{ 0x0003d2, 0x0003d4 }, .{ 0x0003f9, 0x0003fa }, .{ 0x0003fd, 0x00042f },
        .{ 0x0004c0, 0x0004c1 }, .{ 0x000531, 0x000556 }, .{ 0x0010a0, 0x0010c5 },
        .{ 0x0013a0, 0x0013f5 }, .{ 0x001c90, 0x001cba }, .{ 0x001cbd, 0x001cbf },
        .{ 0x001f08, 0x001f0f }, .{ 0x001f18, 0x001f1d }, .{ 0x001f28, 0x001f2f },
        .{ 0x001f38, 0x001f3f }, .{ 0x001f48, 0x001f4d }, .{ 0x001f68, 0x001f6f },
        .{ 0x001fb8, 0x001fbb }, .{ 0x001fc8, 0x001fcb }, .{ 0x001fd8, 0x001fdb },
        .{ 0x001fe8, 0x001fec }, .{ 0x001ff8, 0x001ffb }, .{ 0x00210b, 0x00210d },
        .{ 0x002110, 0x002112 }, .{ 0x002119, 0x00211d }, .{ 0x00212a, 0x00212d },
        .{ 0x002130, 0x002133 }, .{ 0x00213e, 0x00213f }, .{ 0x002160, 0x00216f },
        .{ 0x0024b6, 0x0024cf }, .{ 0x002c00, 0x002c2f }, .{ 0x002c62, 0x002c64 },
        .{ 0x002c6d, 0x002c70 }, .{ 0x002c7e, 0x002c80 }, .{ 0x00a77d, 0x00a77e },
        .{ 0x00a7aa, 0x00a7ae }, .{ 0x00a7b0, 0x00a7b4 }, .{ 0x00a7c4, 0x00a7c7 },
        .{ 0x00a7cb, 0x00a7cc }, .{ 0x00ff21, 0x00ff3a }, .{ 0x010400, 0x010427 },
        .{ 0x0104b0, 0x0104d3 }, .{ 0x010570, 0x01057a }, .{ 0x01057c, 0x01058a },
        .{ 0x01058c, 0x010592 }, .{ 0x010594, 0x010595 }, .{ 0x010c80, 0x010cb2 },
        .{ 0x010d50, 0x010d65 }, .{ 0x0118a0, 0x0118bf }, .{ 0x016e40, 0x016e5f },
        .{ 0x016ea0, 0x016eb8 }, .{ 0x01d400, 0x01d419 }, .{ 0x01d434, 0x01d44d },
        .{ 0x01d468, 0x01d481 }, .{ 0x01d49e, 0x01d49f }, .{ 0x01d4a5, 0x01d4a6 },
        .{ 0x01d4a9, 0x01d4ac }, .{ 0x01d4ae, 0x01d4b5 }, .{ 0x01d4d0, 0x01d4e9 },
        .{ 0x01d504, 0x01d505 }, .{ 0x01d507, 0x01d50a }, .{ 0x01d50d, 0x01d514 },
        .{ 0x01d516, 0x01d51c }, .{ 0x01d538, 0x01d539 }, .{ 0x01d53b, 0x01d53e },
        .{ 0x01d540, 0x01d544 }, .{ 0x01d54a, 0x01d550 }, .{ 0x01d56c, 0x01d585 },
        .{ 0x01d5a0, 0x01d5b9 }, .{ 0x01d5d4, 0x01d5ed }, .{ 0x01d608, 0x01d621 },
        .{ 0x01d63c, 0x01d655 }, .{ 0x01d670, 0x01d689 }, .{ 0x01d6a8, 0x01d6c0 },
        .{ 0x01d6e2, 0x01d6fa }, .{ 0x01d71c, 0x01d734 }, .{ 0x01d756, 0x01d76e },
        .{ 0x01d790, 0x01d7a8 }, .{ 0x01e900, 0x01e921 }, .{ 0x01f130, 0x01f149 },
        .{ 0x01f150, 0x01f169 }, .{ 0x01f170, 0x01f189 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeAssignedCodePoint(code_point: u21) bool {
    return code_point <= 0x10ffff and !isUnicodeUnassignedCodePoint(code_point);
}

pub fn isUnicodeOtherCategoryCodePoint(code_point: u21) bool {
    return code_point <= 0x10ffff and
        (isUnicodeControlCategoryCodePoint(code_point) or
            isUnicodeFormatCategoryCodePoint(code_point) or
            isUnicodePrivateUseCategoryCodePoint(code_point) or
            isUnicodeSurrogateCategoryCodePoint(code_point) or
            isUnicodeUnassignedCodePoint(code_point));
}

pub fn isUnicodeControlCategoryCodePoint(code_point: u21) bool {
    return code_point <= 0x00001f or (code_point >= 0x00007f and code_point <= 0x00009f);
}

pub fn isUnicodeFormatCategoryCodePoint(code_point: u21) bool {
    return code_point == 0x0000ad or
        code_point == 0x00061c or
        code_point == 0x0006dd or
        code_point == 0x00070f or
        code_point == 0x0008e2 or
        code_point == 0x00180e or
        code_point == 0x00feff or
        code_point == 0x0110bd or
        code_point == 0x0110cd or
        code_point == 0x0e0001 or
        (code_point >= 0x000600 and code_point <= 0x000605) or
        (code_point >= 0x000890 and code_point <= 0x000891) or
        (code_point >= 0x00200b and code_point <= 0x00200f) or
        (code_point >= 0x00202a and code_point <= 0x00202e) or
        (code_point >= 0x002060 and code_point <= 0x002064) or
        (code_point >= 0x002066 and code_point <= 0x00206f) or
        (code_point >= 0x00fff9 and code_point <= 0x00fffb) or
        (code_point >= 0x013430 and code_point <= 0x01343f) or
        (code_point >= 0x01bca0 and code_point <= 0x01bca3) or
        (code_point >= 0x01d173 and code_point <= 0x01d17a) or
        (code_point >= 0x0e0020 and code_point <= 0x0e007f);
}

pub fn isUnicodePrivateUseCategoryCodePoint(code_point: u21) bool {
    return (code_point >= 0x00e000 and code_point <= 0x00f8ff) or
        (code_point >= 0x0f0000 and code_point <= 0x0ffffd) or
        (code_point >= 0x100000 and code_point <= 0x10fffd);
}

pub fn isUnicodeSurrogateCategoryCodePoint(code_point: u21) bool {
    return code_point >= 0x00d800 and code_point <= 0x00dfff;
}

pub fn isUnicodeDecimalNumberCategoryCodePoint(code_point: u21) bool {
    const singles = [_]u21{};
    const ranges = [_][2]u21{
        .{ 0x000030, 0x000039 }, .{ 0x000660, 0x000669 }, .{ 0x0006f0, 0x0006f9 },
        .{ 0x0007c0, 0x0007c9 }, .{ 0x000966, 0x00096f }, .{ 0x0009e6, 0x0009ef },
        .{ 0x000a66, 0x000a6f }, .{ 0x000ae6, 0x000aef }, .{ 0x000b66, 0x000b6f },
        .{ 0x000be6, 0x000bef }, .{ 0x000c66, 0x000c6f }, .{ 0x000ce6, 0x000cef },
        .{ 0x000d66, 0x000d6f }, .{ 0x000de6, 0x000def }, .{ 0x000e50, 0x000e59 },
        .{ 0x000ed0, 0x000ed9 }, .{ 0x000f20, 0x000f29 }, .{ 0x001040, 0x001049 },
        .{ 0x001090, 0x001099 }, .{ 0x0017e0, 0x0017e9 }, .{ 0x001810, 0x001819 },
        .{ 0x001946, 0x00194f }, .{ 0x0019d0, 0x0019d9 }, .{ 0x001a80, 0x001a89 },
        .{ 0x001a90, 0x001a99 }, .{ 0x001b50, 0x001b59 }, .{ 0x001bb0, 0x001bb9 },
        .{ 0x001c40, 0x001c49 }, .{ 0x001c50, 0x001c59 }, .{ 0x00a620, 0x00a629 },
        .{ 0x00a8d0, 0x00a8d9 }, .{ 0x00a900, 0x00a909 }, .{ 0x00a9d0, 0x00a9d9 },
        .{ 0x00a9f0, 0x00a9f9 }, .{ 0x00aa50, 0x00aa59 }, .{ 0x00abf0, 0x00abf9 },
        .{ 0x00ff10, 0x00ff19 }, .{ 0x0104a0, 0x0104a9 }, .{ 0x010d30, 0x010d39 },
        .{ 0x010d40, 0x010d49 }, .{ 0x011066, 0x01106f }, .{ 0x0110f0, 0x0110f9 },
        .{ 0x011136, 0x01113f }, .{ 0x0111d0, 0x0111d9 }, .{ 0x0112f0, 0x0112f9 },
        .{ 0x011450, 0x011459 }, .{ 0x0114d0, 0x0114d9 }, .{ 0x011650, 0x011659 },
        .{ 0x0116c0, 0x0116c9 }, .{ 0x0116d0, 0x0116e3 }, .{ 0x011730, 0x011739 },
        .{ 0x0118e0, 0x0118e9 }, .{ 0x011950, 0x011959 }, .{ 0x011bf0, 0x011bf9 },
        .{ 0x011c50, 0x011c59 }, .{ 0x011d50, 0x011d59 }, .{ 0x011da0, 0x011da9 },
        .{ 0x011de0, 0x011de9 }, .{ 0x011f50, 0x011f59 }, .{ 0x016130, 0x016139 },
        .{ 0x016a60, 0x016a69 }, .{ 0x016ac0, 0x016ac9 }, .{ 0x016b50, 0x016b59 },
        .{ 0x016d70, 0x016d79 }, .{ 0x01ccf0, 0x01ccf9 }, .{ 0x01d7ce, 0x01d7ff },
        .{ 0x01e140, 0x01e149 }, .{ 0x01e2f0, 0x01e2f9 }, .{ 0x01e4f0, 0x01e4f9 },
        .{ 0x01e5f1, 0x01e5fa }, .{ 0x01e950, 0x01e959 }, .{ 0x01fbf0, 0x01fbf9 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeMarkCategoryCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0005bf, 0x0005c7, 0x000670, 0x000711, 0x0007fd, 0x0009bc,
        0x0009d7, 0x0009fe, 0x000a3c, 0x000a51, 0x000a75, 0x000abc,
        0x000b3c, 0x000b82, 0x000bd7, 0x000c3c, 0x000cbc, 0x000cf3,
        0x000d57, 0x000dca, 0x000dd6, 0x000e31, 0x000eb1, 0x000f35,
        0x000f37, 0x000f39, 0x000fc6, 0x00108f, 0x0017dd, 0x00180f,
        0x0018a9, 0x001a7f, 0x001ced, 0x001cf4, 0x002d7f, 0x00a802,
        0x00a806, 0x00a80b, 0x00a82c, 0x00a8ff, 0x00a9e5, 0x00aa43,
        0x00aab0, 0x00aac1, 0x00fb1e, 0x0101fd, 0x0102e0, 0x010a3f,
        0x011070, 0x0110c2, 0x011173, 0x01123e, 0x011241, 0x011357,
        0x0113c2, 0x0113c5, 0x0113d2, 0x01145e, 0x011940, 0x0119e4,
        0x011a47, 0x011d3a, 0x011d47, 0x011f03, 0x011f5a, 0x013440,
        0x016f4f, 0x016fe4, 0x01da75, 0x01da84, 0x01e08f, 0x01e2ae,
        0x01e6e3, 0x01e6e6, 0x01e6f5,
    };
    const ranges = [_][2]u21{
        .{ 0x000300, 0x00036f }, .{ 0x000483, 0x000489 }, .{ 0x000591, 0x0005bd },
        .{ 0x0005c1, 0x0005c2 }, .{ 0x0005c4, 0x0005c5 }, .{ 0x000610, 0x00061a },
        .{ 0x00064b, 0x00065f }, .{ 0x0006d6, 0x0006dc }, .{ 0x0006df, 0x0006e4 },
        .{ 0x0006e7, 0x0006e8 }, .{ 0x0006ea, 0x0006ed }, .{ 0x000730, 0x00074a },
        .{ 0x0007a6, 0x0007b0 }, .{ 0x0007eb, 0x0007f3 }, .{ 0x000816, 0x000819 },
        .{ 0x00081b, 0x000823 }, .{ 0x000825, 0x000827 }, .{ 0x000829, 0x00082d },
        .{ 0x000859, 0x00085b }, .{ 0x000897, 0x00089f }, .{ 0x0008ca, 0x0008e1 },
        .{ 0x0008e3, 0x000903 }, .{ 0x00093a, 0x00093c }, .{ 0x00093e, 0x00094f },
        .{ 0x000951, 0x000957 }, .{ 0x000962, 0x000963 }, .{ 0x000981, 0x000983 },
        .{ 0x0009be, 0x0009c4 }, .{ 0x0009c7, 0x0009c8 }, .{ 0x0009cb, 0x0009cd },
        .{ 0x0009e2, 0x0009e3 }, .{ 0x000a01, 0x000a03 }, .{ 0x000a3e, 0x000a42 },
        .{ 0x000a47, 0x000a48 }, .{ 0x000a4b, 0x000a4d }, .{ 0x000a70, 0x000a71 },
        .{ 0x000a81, 0x000a83 }, .{ 0x000abe, 0x000ac5 }, .{ 0x000ac7, 0x000ac9 },
        .{ 0x000acb, 0x000acd }, .{ 0x000ae2, 0x000ae3 }, .{ 0x000afa, 0x000aff },
        .{ 0x000b01, 0x000b03 }, .{ 0x000b3e, 0x000b44 }, .{ 0x000b47, 0x000b48 },
        .{ 0x000b4b, 0x000b4d }, .{ 0x000b55, 0x000b57 }, .{ 0x000b62, 0x000b63 },
        .{ 0x000bbe, 0x000bc2 }, .{ 0x000bc6, 0x000bc8 }, .{ 0x000bca, 0x000bcd },
        .{ 0x000c00, 0x000c04 }, .{ 0x000c3e, 0x000c44 }, .{ 0x000c46, 0x000c48 },
        .{ 0x000c4a, 0x000c4d }, .{ 0x000c55, 0x000c56 }, .{ 0x000c62, 0x000c63 },
        .{ 0x000c81, 0x000c83 }, .{ 0x000cbe, 0x000cc4 }, .{ 0x000cc6, 0x000cc8 },
        .{ 0x000cca, 0x000ccd }, .{ 0x000cd5, 0x000cd6 }, .{ 0x000ce2, 0x000ce3 },
        .{ 0x000d00, 0x000d03 }, .{ 0x000d3b, 0x000d3c }, .{ 0x000d3e, 0x000d44 },
        .{ 0x000d46, 0x000d48 }, .{ 0x000d4a, 0x000d4d }, .{ 0x000d62, 0x000d63 },
        .{ 0x000d81, 0x000d83 }, .{ 0x000dcf, 0x000dd4 }, .{ 0x000dd8, 0x000ddf },
        .{ 0x000df2, 0x000df3 }, .{ 0x000e34, 0x000e3a }, .{ 0x000e47, 0x000e4e },
        .{ 0x000eb4, 0x000ebc }, .{ 0x000ec8, 0x000ece }, .{ 0x000f18, 0x000f19 },
        .{ 0x000f3e, 0x000f3f }, .{ 0x000f71, 0x000f84 }, .{ 0x000f86, 0x000f87 },
        .{ 0x000f8d, 0x000f97 }, .{ 0x000f99, 0x000fbc }, .{ 0x00102b, 0x00103e },
        .{ 0x001056, 0x001059 }, .{ 0x00105e, 0x001060 }, .{ 0x001062, 0x001064 },
        .{ 0x001067, 0x00106d }, .{ 0x001071, 0x001074 }, .{ 0x001082, 0x00108d },
        .{ 0x00109a, 0x00109d }, .{ 0x00135d, 0x00135f }, .{ 0x001712, 0x001715 },
        .{ 0x001732, 0x001734 }, .{ 0x001752, 0x001753 }, .{ 0x001772, 0x001773 },
        .{ 0x0017b4, 0x0017d3 }, .{ 0x00180b, 0x00180d }, .{ 0x001885, 0x001886 },
        .{ 0x001920, 0x00192b }, .{ 0x001930, 0x00193b }, .{ 0x001a17, 0x001a1b },
        .{ 0x001a55, 0x001a5e }, .{ 0x001a60, 0x001a7c }, .{ 0x001ab0, 0x001add },
        .{ 0x001ae0, 0x001aeb }, .{ 0x001b00, 0x001b04 }, .{ 0x001b34, 0x001b44 },
        .{ 0x001b6b, 0x001b73 }, .{ 0x001b80, 0x001b82 }, .{ 0x001ba1, 0x001bad },
        .{ 0x001be6, 0x001bf3 }, .{ 0x001c24, 0x001c37 }, .{ 0x001cd0, 0x001cd2 },
        .{ 0x001cd4, 0x001ce8 }, .{ 0x001cf7, 0x001cf9 }, .{ 0x001dc0, 0x001dff },
        .{ 0x0020d0, 0x0020f0 }, .{ 0x002cef, 0x002cf1 }, .{ 0x002de0, 0x002dff },
        .{ 0x00302a, 0x00302f }, .{ 0x003099, 0x00309a }, .{ 0x00a66f, 0x00a672 },
        .{ 0x00a674, 0x00a67d }, .{ 0x00a69e, 0x00a69f }, .{ 0x00a6f0, 0x00a6f1 },
        .{ 0x00a823, 0x00a827 }, .{ 0x00a880, 0x00a881 }, .{ 0x00a8b4, 0x00a8c5 },
        .{ 0x00a8e0, 0x00a8f1 }, .{ 0x00a926, 0x00a92d }, .{ 0x00a947, 0x00a953 },
        .{ 0x00a980, 0x00a983 }, .{ 0x00a9b3, 0x00a9c0 }, .{ 0x00aa29, 0x00aa36 },
        .{ 0x00aa4c, 0x00aa4d }, .{ 0x00aa7b, 0x00aa7d }, .{ 0x00aab2, 0x00aab4 },
        .{ 0x00aab7, 0x00aab8 }, .{ 0x00aabe, 0x00aabf }, .{ 0x00aaeb, 0x00aaef },
        .{ 0x00aaf5, 0x00aaf6 }, .{ 0x00abe3, 0x00abea }, .{ 0x00abec, 0x00abed },
        .{ 0x00fe00, 0x00fe0f }, .{ 0x00fe20, 0x00fe2f }, .{ 0x010376, 0x01037a },
        .{ 0x010a01, 0x010a03 }, .{ 0x010a05, 0x010a06 }, .{ 0x010a0c, 0x010a0f },
        .{ 0x010a38, 0x010a3a }, .{ 0x010ae5, 0x010ae6 }, .{ 0x010d24, 0x010d27 },
        .{ 0x010d69, 0x010d6d }, .{ 0x010eab, 0x010eac }, .{ 0x010efa, 0x010eff },
        .{ 0x010f46, 0x010f50 }, .{ 0x010f82, 0x010f85 }, .{ 0x011000, 0x011002 },
        .{ 0x011038, 0x011046 }, .{ 0x011073, 0x011074 }, .{ 0x01107f, 0x011082 },
        .{ 0x0110b0, 0x0110ba }, .{ 0x011100, 0x011102 }, .{ 0x011127, 0x011134 },
        .{ 0x011145, 0x011146 }, .{ 0x011180, 0x011182 }, .{ 0x0111b3, 0x0111c0 },
        .{ 0x0111c9, 0x0111cc }, .{ 0x0111ce, 0x0111cf }, .{ 0x01122c, 0x011237 },
        .{ 0x0112df, 0x0112ea }, .{ 0x011300, 0x011303 }, .{ 0x01133b, 0x01133c },
        .{ 0x01133e, 0x011344 }, .{ 0x011347, 0x011348 }, .{ 0x01134b, 0x01134d },
        .{ 0x011362, 0x011363 }, .{ 0x011366, 0x01136c }, .{ 0x011370, 0x011374 },
        .{ 0x0113b8, 0x0113c0 }, .{ 0x0113c7, 0x0113ca }, .{ 0x0113cc, 0x0113d0 },
        .{ 0x0113e1, 0x0113e2 }, .{ 0x011435, 0x011446 }, .{ 0x0114b0, 0x0114c3 },
        .{ 0x0115af, 0x0115b5 }, .{ 0x0115b8, 0x0115c0 }, .{ 0x0115dc, 0x0115dd },
        .{ 0x011630, 0x011640 }, .{ 0x0116ab, 0x0116b7 }, .{ 0x01171d, 0x01172b },
        .{ 0x01182c, 0x01183a }, .{ 0x011930, 0x011935 }, .{ 0x011937, 0x011938 },
        .{ 0x01193b, 0x01193e }, .{ 0x011942, 0x011943 }, .{ 0x0119d1, 0x0119d7 },
        .{ 0x0119da, 0x0119e0 }, .{ 0x011a01, 0x011a0a }, .{ 0x011a33, 0x011a39 },
        .{ 0x011a3b, 0x011a3e }, .{ 0x011a51, 0x011a5b }, .{ 0x011a8a, 0x011a99 },
        .{ 0x011b60, 0x011b67 }, .{ 0x011c2f, 0x011c36 }, .{ 0x011c38, 0x011c3f },
        .{ 0x011c92, 0x011ca7 }, .{ 0x011ca9, 0x011cb6 }, .{ 0x011d31, 0x011d36 },
        .{ 0x011d3c, 0x011d3d }, .{ 0x011d3f, 0x011d45 }, .{ 0x011d8a, 0x011d8e },
        .{ 0x011d90, 0x011d91 }, .{ 0x011d93, 0x011d97 }, .{ 0x011ef3, 0x011ef6 },
        .{ 0x011f00, 0x011f01 }, .{ 0x011f34, 0x011f3a }, .{ 0x011f3e, 0x011f42 },
        .{ 0x013447, 0x013455 }, .{ 0x01611e, 0x01612f }, .{ 0x016af0, 0x016af4 },
        .{ 0x016b30, 0x016b36 }, .{ 0x016f51, 0x016f87 }, .{ 0x016f8f, 0x016f92 },
        .{ 0x016ff0, 0x016ff1 }, .{ 0x01bc9d, 0x01bc9e }, .{ 0x01cf00, 0x01cf2d },
        .{ 0x01cf30, 0x01cf46 }, .{ 0x01d165, 0x01d169 }, .{ 0x01d16d, 0x01d172 },
        .{ 0x01d17b, 0x01d182 }, .{ 0x01d185, 0x01d18b }, .{ 0x01d1aa, 0x01d1ad },
        .{ 0x01d242, 0x01d244 }, .{ 0x01da00, 0x01da36 }, .{ 0x01da3b, 0x01da6c },
        .{ 0x01da9b, 0x01da9f }, .{ 0x01daa1, 0x01daaf }, .{ 0x01e000, 0x01e006 },
        .{ 0x01e008, 0x01e018 }, .{ 0x01e01b, 0x01e021 }, .{ 0x01e023, 0x01e024 },
        .{ 0x01e026, 0x01e02a }, .{ 0x01e130, 0x01e136 }, .{ 0x01e2ec, 0x01e2ef },
        .{ 0x01e4ec, 0x01e4ef }, .{ 0x01e5ee, 0x01e5ef }, .{ 0x01e6ee, 0x01e6ef },
        .{ 0x01e8d0, 0x01e8d6 }, .{ 0x01e944, 0x01e94a }, .{ 0x0e0100, 0x0e01ef },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeLetterCategoryCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000aa, 0x0000b5, 0x0000ba, 0x0002ec, 0x0002ee, 0x00037f, 0x000386, 0x00038c,
        0x000559, 0x0006d5, 0x0006ff, 0x000710, 0x0007b1, 0x0007fa, 0x00081a, 0x000824,
        0x000828, 0x00093d, 0x000950, 0x0009b2, 0x0009bd, 0x0009ce, 0x0009fc, 0x000a5e,
        0x000abd, 0x000ad0, 0x000af9, 0x000b3d, 0x000b71, 0x000b83, 0x000b9c, 0x000bd0,
        0x000c3d, 0x000c80, 0x000cbd, 0x000d3d, 0x000d4e, 0x000dbd, 0x000e84, 0x000ea5,
        0x000ebd, 0x000ec6, 0x000f00, 0x00103f, 0x001061, 0x00108e, 0x0010c7, 0x0010cd,
        0x001258, 0x0012c0, 0x0017d7, 0x0017dc, 0x0018aa, 0x001aa7, 0x001cfa, 0x001f59,
        0x001f5b, 0x001f5d, 0x001fbe, 0x002071, 0x00207f, 0x002102, 0x002107, 0x002115,
        0x002124, 0x002126, 0x002128, 0x00214e, 0x002d27, 0x002d2d, 0x002d6f, 0x002e2f,
        0x00a8fb, 0x00a9cf, 0x00aa7a, 0x00aab1, 0x00aac0, 0x00aac2, 0x00fb1d, 0x00fb3e,
        0x010808, 0x01083c, 0x010a00, 0x010f27, 0x011075, 0x011144, 0x011147, 0x011176,
        0x0111da, 0x0111dc, 0x011288, 0x01133d, 0x011350, 0x01138b, 0x01138e, 0x0113b7,
        0x0113d1, 0x0113d3, 0x0114c7, 0x011644, 0x0116b8, 0x011909, 0x01193f, 0x011941,
        0x0119e1, 0x0119e3, 0x011a00, 0x011a3a, 0x011a50, 0x011a9d, 0x011c40, 0x011d46,
        0x011d98, 0x011f02, 0x011fb0, 0x016f50, 0x016fe3, 0x01b132, 0x01b155, 0x01d4a2,
        0x01d4bb, 0x01d546, 0x01e14e, 0x01e5f0, 0x01e94b, 0x01ee24, 0x01ee27, 0x01ee39,
        0x01ee3b, 0x01ee42, 0x01ee47, 0x01ee49, 0x01ee4b, 0x01ee54, 0x01ee57, 0x01ee59,
        0x01ee5b, 0x01ee5d, 0x01ee5f, 0x01ee64, 0x01ee7e,
    };
    const ranges = [_][2]u21{
        .{ 0x000041, 0x00005a }, .{ 0x000061, 0x00007a }, .{ 0x0000c0, 0x0000d6 },
        .{ 0x0000d8, 0x0000f6 }, .{ 0x0000f8, 0x0002c1 }, .{ 0x0002c6, 0x0002d1 },
        .{ 0x0002e0, 0x0002e4 }, .{ 0x000370, 0x000374 }, .{ 0x000376, 0x000377 },
        .{ 0x00037a, 0x00037d }, .{ 0x000388, 0x00038a }, .{ 0x00038e, 0x0003a1 },
        .{ 0x0003a3, 0x0003f5 }, .{ 0x0003f7, 0x000481 }, .{ 0x00048a, 0x00052f },
        .{ 0x000531, 0x000556 }, .{ 0x000560, 0x000588 }, .{ 0x0005d0, 0x0005ea },
        .{ 0x0005ef, 0x0005f2 }, .{ 0x000620, 0x00064a }, .{ 0x00066e, 0x00066f },
        .{ 0x000671, 0x0006d3 }, .{ 0x0006e5, 0x0006e6 }, .{ 0x0006ee, 0x0006ef },
        .{ 0x0006fa, 0x0006fc }, .{ 0x000712, 0x00072f }, .{ 0x00074d, 0x0007a5 },
        .{ 0x0007ca, 0x0007ea }, .{ 0x0007f4, 0x0007f5 }, .{ 0x000800, 0x000815 },
        .{ 0x000840, 0x000858 }, .{ 0x000860, 0x00086a }, .{ 0x000870, 0x000887 },
        .{ 0x000889, 0x00088f }, .{ 0x0008a0, 0x0008c9 }, .{ 0x000904, 0x000939 },
        .{ 0x000958, 0x000961 }, .{ 0x000971, 0x000980 }, .{ 0x000985, 0x00098c },
        .{ 0x00098f, 0x000990 }, .{ 0x000993, 0x0009a8 }, .{ 0x0009aa, 0x0009b0 },
        .{ 0x0009b6, 0x0009b9 }, .{ 0x0009dc, 0x0009dd }, .{ 0x0009df, 0x0009e1 },
        .{ 0x0009f0, 0x0009f1 }, .{ 0x000a05, 0x000a0a }, .{ 0x000a0f, 0x000a10 },
        .{ 0x000a13, 0x000a28 }, .{ 0x000a2a, 0x000a30 }, .{ 0x000a32, 0x000a33 },
        .{ 0x000a35, 0x000a36 }, .{ 0x000a38, 0x000a39 }, .{ 0x000a59, 0x000a5c },
        .{ 0x000a72, 0x000a74 }, .{ 0x000a85, 0x000a8d }, .{ 0x000a8f, 0x000a91 },
        .{ 0x000a93, 0x000aa8 }, .{ 0x000aaa, 0x000ab0 }, .{ 0x000ab2, 0x000ab3 },
        .{ 0x000ab5, 0x000ab9 }, .{ 0x000ae0, 0x000ae1 }, .{ 0x000b05, 0x000b0c },
        .{ 0x000b0f, 0x000b10 }, .{ 0x000b13, 0x000b28 }, .{ 0x000b2a, 0x000b30 },
        .{ 0x000b32, 0x000b33 }, .{ 0x000b35, 0x000b39 }, .{ 0x000b5c, 0x000b5d },
        .{ 0x000b5f, 0x000b61 }, .{ 0x000b85, 0x000b8a }, .{ 0x000b8e, 0x000b90 },
        .{ 0x000b92, 0x000b95 }, .{ 0x000b99, 0x000b9a }, .{ 0x000b9e, 0x000b9f },
        .{ 0x000ba3, 0x000ba4 }, .{ 0x000ba8, 0x000baa }, .{ 0x000bae, 0x000bb9 },
        .{ 0x000c05, 0x000c0c }, .{ 0x000c0e, 0x000c10 }, .{ 0x000c12, 0x000c28 },
        .{ 0x000c2a, 0x000c39 }, .{ 0x000c58, 0x000c5a }, .{ 0x000c5c, 0x000c5d },
        .{ 0x000c60, 0x000c61 }, .{ 0x000c85, 0x000c8c }, .{ 0x000c8e, 0x000c90 },
        .{ 0x000c92, 0x000ca8 }, .{ 0x000caa, 0x000cb3 }, .{ 0x000cb5, 0x000cb9 },
        .{ 0x000cdc, 0x000cde }, .{ 0x000ce0, 0x000ce1 }, .{ 0x000cf1, 0x000cf2 },
        .{ 0x000d04, 0x000d0c }, .{ 0x000d0e, 0x000d10 }, .{ 0x000d12, 0x000d3a },
        .{ 0x000d54, 0x000d56 }, .{ 0x000d5f, 0x000d61 }, .{ 0x000d7a, 0x000d7f },
        .{ 0x000d85, 0x000d96 }, .{ 0x000d9a, 0x000db1 }, .{ 0x000db3, 0x000dbb },
        .{ 0x000dc0, 0x000dc6 }, .{ 0x000e01, 0x000e30 }, .{ 0x000e32, 0x000e33 },
        .{ 0x000e40, 0x000e46 }, .{ 0x000e81, 0x000e82 }, .{ 0x000e86, 0x000e8a },
        .{ 0x000e8c, 0x000ea3 }, .{ 0x000ea7, 0x000eb0 }, .{ 0x000eb2, 0x000eb3 },
        .{ 0x000ec0, 0x000ec4 }, .{ 0x000edc, 0x000edf }, .{ 0x000f40, 0x000f47 },
        .{ 0x000f49, 0x000f6c }, .{ 0x000f88, 0x000f8c }, .{ 0x001000, 0x00102a },
        .{ 0x001050, 0x001055 }, .{ 0x00105a, 0x00105d }, .{ 0x001065, 0x001066 },
        .{ 0x00106e, 0x001070 }, .{ 0x001075, 0x001081 }, .{ 0x0010a0, 0x0010c5 },
        .{ 0x0010d0, 0x0010fa }, .{ 0x0010fc, 0x001248 }, .{ 0x00124a, 0x00124d },
        .{ 0x001250, 0x001256 }, .{ 0x00125a, 0x00125d }, .{ 0x001260, 0x001288 },
        .{ 0x00128a, 0x00128d }, .{ 0x001290, 0x0012b0 }, .{ 0x0012b2, 0x0012b5 },
        .{ 0x0012b8, 0x0012be }, .{ 0x0012c2, 0x0012c5 }, .{ 0x0012c8, 0x0012d6 },
        .{ 0x0012d8, 0x001310 }, .{ 0x001312, 0x001315 }, .{ 0x001318, 0x00135a },
        .{ 0x001380, 0x00138f }, .{ 0x0013a0, 0x0013f5 }, .{ 0x0013f8, 0x0013fd },
        .{ 0x001401, 0x00166c }, .{ 0x00166f, 0x00167f }, .{ 0x001681, 0x00169a },
        .{ 0x0016a0, 0x0016ea }, .{ 0x0016f1, 0x0016f8 }, .{ 0x001700, 0x001711 },
        .{ 0x00171f, 0x001731 }, .{ 0x001740, 0x001751 }, .{ 0x001760, 0x00176c },
        .{ 0x00176e, 0x001770 }, .{ 0x001780, 0x0017b3 }, .{ 0x001820, 0x001878 },
        .{ 0x001880, 0x001884 }, .{ 0x001887, 0x0018a8 }, .{ 0x0018b0, 0x0018f5 },
        .{ 0x001900, 0x00191e }, .{ 0x001950, 0x00196d }, .{ 0x001970, 0x001974 },
        .{ 0x001980, 0x0019ab }, .{ 0x0019b0, 0x0019c9 }, .{ 0x001a00, 0x001a16 },
        .{ 0x001a20, 0x001a54 }, .{ 0x001b05, 0x001b33 }, .{ 0x001b45, 0x001b4c },
        .{ 0x001b83, 0x001ba0 }, .{ 0x001bae, 0x001baf }, .{ 0x001bba, 0x001be5 },
        .{ 0x001c00, 0x001c23 }, .{ 0x001c4d, 0x001c4f }, .{ 0x001c5a, 0x001c7d },
        .{ 0x001c80, 0x001c8a }, .{ 0x001c90, 0x001cba }, .{ 0x001cbd, 0x001cbf },
        .{ 0x001ce9, 0x001cec }, .{ 0x001cee, 0x001cf3 }, .{ 0x001cf5, 0x001cf6 },
        .{ 0x001d00, 0x001dbf }, .{ 0x001e00, 0x001f15 }, .{ 0x001f18, 0x001f1d },
        .{ 0x001f20, 0x001f45 }, .{ 0x001f48, 0x001f4d }, .{ 0x001f50, 0x001f57 },
        .{ 0x001f5f, 0x001f7d }, .{ 0x001f80, 0x001fb4 }, .{ 0x001fb6, 0x001fbc },
        .{ 0x001fc2, 0x001fc4 }, .{ 0x001fc6, 0x001fcc }, .{ 0x001fd0, 0x001fd3 },
        .{ 0x001fd6, 0x001fdb }, .{ 0x001fe0, 0x001fec }, .{ 0x001ff2, 0x001ff4 },
        .{ 0x001ff6, 0x001ffc }, .{ 0x002090, 0x00209c }, .{ 0x00210a, 0x002113 },
        .{ 0x002119, 0x00211d }, .{ 0x00212a, 0x00212d }, .{ 0x00212f, 0x002139 },
        .{ 0x00213c, 0x00213f }, .{ 0x002145, 0x002149 }, .{ 0x002183, 0x002184 },
        .{ 0x002c00, 0x002ce4 }, .{ 0x002ceb, 0x002cee }, .{ 0x002cf2, 0x002cf3 },
        .{ 0x002d00, 0x002d25 }, .{ 0x002d30, 0x002d67 }, .{ 0x002d80, 0x002d96 },
        .{ 0x002da0, 0x002da6 }, .{ 0x002da8, 0x002dae }, .{ 0x002db0, 0x002db6 },
        .{ 0x002db8, 0x002dbe }, .{ 0x002dc0, 0x002dc6 }, .{ 0x002dc8, 0x002dce },
        .{ 0x002dd0, 0x002dd6 }, .{ 0x002dd8, 0x002dde }, .{ 0x003005, 0x003006 },
        .{ 0x003031, 0x003035 }, .{ 0x00303b, 0x00303c }, .{ 0x003041, 0x003096 },
        .{ 0x00309d, 0x00309f }, .{ 0x0030a1, 0x0030fa }, .{ 0x0030fc, 0x0030ff },
        .{ 0x003105, 0x00312f }, .{ 0x003131, 0x00318e }, .{ 0x0031a0, 0x0031bf },
        .{ 0x0031f0, 0x0031ff }, .{ 0x003400, 0x004dbf }, .{ 0x004e00, 0x00a48c },
        .{ 0x00a4d0, 0x00a4fd }, .{ 0x00a500, 0x00a60c }, .{ 0x00a610, 0x00a61f },
        .{ 0x00a62a, 0x00a62b }, .{ 0x00a640, 0x00a66e }, .{ 0x00a67f, 0x00a69d },
        .{ 0x00a6a0, 0x00a6e5 }, .{ 0x00a717, 0x00a71f }, .{ 0x00a722, 0x00a788 },
        .{ 0x00a78b, 0x00a7dc }, .{ 0x00a7f1, 0x00a801 }, .{ 0x00a803, 0x00a805 },
        .{ 0x00a807, 0x00a80a }, .{ 0x00a80c, 0x00a822 }, .{ 0x00a840, 0x00a873 },
        .{ 0x00a882, 0x00a8b3 }, .{ 0x00a8f2, 0x00a8f7 }, .{ 0x00a8fd, 0x00a8fe },
        .{ 0x00a90a, 0x00a925 }, .{ 0x00a930, 0x00a946 }, .{ 0x00a960, 0x00a97c },
        .{ 0x00a984, 0x00a9b2 }, .{ 0x00a9e0, 0x00a9e4 }, .{ 0x00a9e6, 0x00a9ef },
        .{ 0x00a9fa, 0x00a9fe }, .{ 0x00aa00, 0x00aa28 }, .{ 0x00aa40, 0x00aa42 },
        .{ 0x00aa44, 0x00aa4b }, .{ 0x00aa60, 0x00aa76 }, .{ 0x00aa7e, 0x00aaaf },
        .{ 0x00aab5, 0x00aab6 }, .{ 0x00aab9, 0x00aabd }, .{ 0x00aadb, 0x00aadd },
        .{ 0x00aae0, 0x00aaea }, .{ 0x00aaf2, 0x00aaf4 }, .{ 0x00ab01, 0x00ab06 },
        .{ 0x00ab09, 0x00ab0e }, .{ 0x00ab11, 0x00ab16 }, .{ 0x00ab20, 0x00ab26 },
        .{ 0x00ab28, 0x00ab2e }, .{ 0x00ab30, 0x00ab5a }, .{ 0x00ab5c, 0x00ab69 },
        .{ 0x00ab70, 0x00abe2 }, .{ 0x00ac00, 0x00d7a3 }, .{ 0x00d7b0, 0x00d7c6 },
        .{ 0x00d7cb, 0x00d7fb }, .{ 0x00f900, 0x00fa6d }, .{ 0x00fa70, 0x00fad9 },
        .{ 0x00fb00, 0x00fb06 }, .{ 0x00fb13, 0x00fb17 }, .{ 0x00fb1f, 0x00fb28 },
        .{ 0x00fb2a, 0x00fb36 }, .{ 0x00fb38, 0x00fb3c }, .{ 0x00fb40, 0x00fb41 },
        .{ 0x00fb43, 0x00fb44 }, .{ 0x00fb46, 0x00fbb1 }, .{ 0x00fbd3, 0x00fd3d },
        .{ 0x00fd50, 0x00fd8f }, .{ 0x00fd92, 0x00fdc7 }, .{ 0x00fdf0, 0x00fdfb },
        .{ 0x00fe70, 0x00fe74 }, .{ 0x00fe76, 0x00fefc }, .{ 0x00ff21, 0x00ff3a },
        .{ 0x00ff41, 0x00ff5a }, .{ 0x00ff66, 0x00ffbe }, .{ 0x00ffc2, 0x00ffc7 },
        .{ 0x00ffca, 0x00ffcf }, .{ 0x00ffd2, 0x00ffd7 }, .{ 0x00ffda, 0x00ffdc },
        .{ 0x010000, 0x01000b }, .{ 0x01000d, 0x010026 }, .{ 0x010028, 0x01003a },
        .{ 0x01003c, 0x01003d }, .{ 0x01003f, 0x01004d }, .{ 0x010050, 0x01005d },
        .{ 0x010080, 0x0100fa }, .{ 0x010280, 0x01029c }, .{ 0x0102a0, 0x0102d0 },
        .{ 0x010300, 0x01031f }, .{ 0x01032d, 0x010340 }, .{ 0x010342, 0x010349 },
        .{ 0x010350, 0x010375 }, .{ 0x010380, 0x01039d }, .{ 0x0103a0, 0x0103c3 },
        .{ 0x0103c8, 0x0103cf }, .{ 0x010400, 0x01049d }, .{ 0x0104b0, 0x0104d3 },
        .{ 0x0104d8, 0x0104fb }, .{ 0x010500, 0x010527 }, .{ 0x010530, 0x010563 },
        .{ 0x010570, 0x01057a }, .{ 0x01057c, 0x01058a }, .{ 0x01058c, 0x010592 },
        .{ 0x010594, 0x010595 }, .{ 0x010597, 0x0105a1 }, .{ 0x0105a3, 0x0105b1 },
        .{ 0x0105b3, 0x0105b9 }, .{ 0x0105bb, 0x0105bc }, .{ 0x0105c0, 0x0105f3 },
        .{ 0x010600, 0x010736 }, .{ 0x010740, 0x010755 }, .{ 0x010760, 0x010767 },
        .{ 0x010780, 0x010785 }, .{ 0x010787, 0x0107b0 }, .{ 0x0107b2, 0x0107ba },
        .{ 0x010800, 0x010805 }, .{ 0x01080a, 0x010835 }, .{ 0x010837, 0x010838 },
        .{ 0x01083f, 0x010855 }, .{ 0x010860, 0x010876 }, .{ 0x010880, 0x01089e },
        .{ 0x0108e0, 0x0108f2 }, .{ 0x0108f4, 0x0108f5 }, .{ 0x010900, 0x010915 },
        .{ 0x010920, 0x010939 }, .{ 0x010940, 0x010959 }, .{ 0x010980, 0x0109b7 },
        .{ 0x0109be, 0x0109bf }, .{ 0x010a10, 0x010a13 }, .{ 0x010a15, 0x010a17 },
        .{ 0x010a19, 0x010a35 }, .{ 0x010a60, 0x010a7c }, .{ 0x010a80, 0x010a9c },
        .{ 0x010ac0, 0x010ac7 }, .{ 0x010ac9, 0x010ae4 }, .{ 0x010b00, 0x010b35 },
        .{ 0x010b40, 0x010b55 }, .{ 0x010b60, 0x010b72 }, .{ 0x010b80, 0x010b91 },
        .{ 0x010c00, 0x010c48 }, .{ 0x010c80, 0x010cb2 }, .{ 0x010cc0, 0x010cf2 },
        .{ 0x010d00, 0x010d23 }, .{ 0x010d4a, 0x010d65 }, .{ 0x010d6f, 0x010d85 },
        .{ 0x010e80, 0x010ea9 }, .{ 0x010eb0, 0x010eb1 }, .{ 0x010ec2, 0x010ec7 },
        .{ 0x010f00, 0x010f1c }, .{ 0x010f30, 0x010f45 }, .{ 0x010f70, 0x010f81 },
        .{ 0x010fb0, 0x010fc4 }, .{ 0x010fe0, 0x010ff6 }, .{ 0x011003, 0x011037 },
        .{ 0x011071, 0x011072 }, .{ 0x011083, 0x0110af }, .{ 0x0110d0, 0x0110e8 },
        .{ 0x011103, 0x011126 }, .{ 0x011150, 0x011172 }, .{ 0x011183, 0x0111b2 },
        .{ 0x0111c1, 0x0111c4 }, .{ 0x011200, 0x011211 }, .{ 0x011213, 0x01122b },
        .{ 0x01123f, 0x011240 }, .{ 0x011280, 0x011286 }, .{ 0x01128a, 0x01128d },
        .{ 0x01128f, 0x01129d }, .{ 0x01129f, 0x0112a8 }, .{ 0x0112b0, 0x0112de },
        .{ 0x011305, 0x01130c }, .{ 0x01130f, 0x011310 }, .{ 0x011313, 0x011328 },
        .{ 0x01132a, 0x011330 }, .{ 0x011332, 0x011333 }, .{ 0x011335, 0x011339 },
        .{ 0x01135d, 0x011361 }, .{ 0x011380, 0x011389 }, .{ 0x011390, 0x0113b5 },
        .{ 0x011400, 0x011434 }, .{ 0x011447, 0x01144a }, .{ 0x01145f, 0x011461 },
        .{ 0x011480, 0x0114af }, .{ 0x0114c4, 0x0114c5 }, .{ 0x011580, 0x0115ae },
        .{ 0x0115d8, 0x0115db }, .{ 0x011600, 0x01162f }, .{ 0x011680, 0x0116aa },
        .{ 0x011700, 0x01171a }, .{ 0x011740, 0x011746 }, .{ 0x011800, 0x01182b },
        .{ 0x0118a0, 0x0118df }, .{ 0x0118ff, 0x011906 }, .{ 0x01190c, 0x011913 },
        .{ 0x011915, 0x011916 }, .{ 0x011918, 0x01192f }, .{ 0x0119a0, 0x0119a7 },
        .{ 0x0119aa, 0x0119d0 }, .{ 0x011a0b, 0x011a32 }, .{ 0x011a5c, 0x011a89 },
        .{ 0x011ab0, 0x011af8 }, .{ 0x011bc0, 0x011be0 }, .{ 0x011c00, 0x011c08 },
        .{ 0x011c0a, 0x011c2e }, .{ 0x011c72, 0x011c8f }, .{ 0x011d00, 0x011d06 },
        .{ 0x011d08, 0x011d09 }, .{ 0x011d0b, 0x011d30 }, .{ 0x011d60, 0x011d65 },
        .{ 0x011d67, 0x011d68 }, .{ 0x011d6a, 0x011d89 }, .{ 0x011db0, 0x011ddb },
        .{ 0x011ee0, 0x011ef2 }, .{ 0x011f04, 0x011f10 }, .{ 0x011f12, 0x011f33 },
        .{ 0x012000, 0x012399 }, .{ 0x012480, 0x012543 }, .{ 0x012f90, 0x012ff0 },
        .{ 0x013000, 0x01342f }, .{ 0x013441, 0x013446 }, .{ 0x013460, 0x0143fa },
        .{ 0x014400, 0x014646 }, .{ 0x016100, 0x01611d }, .{ 0x016800, 0x016a38 },
        .{ 0x016a40, 0x016a5e }, .{ 0x016a70, 0x016abe }, .{ 0x016ad0, 0x016aed },
        .{ 0x016b00, 0x016b2f }, .{ 0x016b40, 0x016b43 }, .{ 0x016b63, 0x016b77 },
        .{ 0x016b7d, 0x016b8f }, .{ 0x016d40, 0x016d6c }, .{ 0x016e40, 0x016e7f },
        .{ 0x016ea0, 0x016eb8 }, .{ 0x016ebb, 0x016ed3 }, .{ 0x016f00, 0x016f4a },
        .{ 0x016f93, 0x016f9f }, .{ 0x016fe0, 0x016fe1 }, .{ 0x016ff2, 0x016ff3 },
        .{ 0x017000, 0x018cd5 }, .{ 0x018cff, 0x018d1e }, .{ 0x018d80, 0x018df2 },
        .{ 0x01aff0, 0x01aff3 }, .{ 0x01aff5, 0x01affb }, .{ 0x01affd, 0x01affe },
        .{ 0x01b000, 0x01b122 }, .{ 0x01b150, 0x01b152 }, .{ 0x01b164, 0x01b167 },
        .{ 0x01b170, 0x01b2fb }, .{ 0x01bc00, 0x01bc6a }, .{ 0x01bc70, 0x01bc7c },
        .{ 0x01bc80, 0x01bc88 }, .{ 0x01bc90, 0x01bc99 }, .{ 0x01d400, 0x01d454 },
        .{ 0x01d456, 0x01d49c }, .{ 0x01d49e, 0x01d49f }, .{ 0x01d4a5, 0x01d4a6 },
        .{ 0x01d4a9, 0x01d4ac }, .{ 0x01d4ae, 0x01d4b9 }, .{ 0x01d4bd, 0x01d4c3 },
        .{ 0x01d4c5, 0x01d505 }, .{ 0x01d507, 0x01d50a }, .{ 0x01d50d, 0x01d514 },
        .{ 0x01d516, 0x01d51c }, .{ 0x01d51e, 0x01d539 }, .{ 0x01d53b, 0x01d53e },
        .{ 0x01d540, 0x01d544 }, .{ 0x01d54a, 0x01d550 }, .{ 0x01d552, 0x01d6a5 },
        .{ 0x01d6a8, 0x01d6c0 }, .{ 0x01d6c2, 0x01d6da }, .{ 0x01d6dc, 0x01d6fa },
        .{ 0x01d6fc, 0x01d714 }, .{ 0x01d716, 0x01d734 }, .{ 0x01d736, 0x01d74e },
        .{ 0x01d750, 0x01d76e }, .{ 0x01d770, 0x01d788 }, .{ 0x01d78a, 0x01d7a8 },
        .{ 0x01d7aa, 0x01d7c2 }, .{ 0x01d7c4, 0x01d7cb }, .{ 0x01df00, 0x01df1e },
        .{ 0x01df25, 0x01df2a }, .{ 0x01e030, 0x01e06d }, .{ 0x01e100, 0x01e12c },
        .{ 0x01e137, 0x01e13d }, .{ 0x01e290, 0x01e2ad }, .{ 0x01e2c0, 0x01e2eb },
        .{ 0x01e4d0, 0x01e4eb }, .{ 0x01e5d0, 0x01e5ed }, .{ 0x01e6c0, 0x01e6de },
        .{ 0x01e6e0, 0x01e6e2 }, .{ 0x01e6e4, 0x01e6e5 }, .{ 0x01e6e7, 0x01e6ed },
        .{ 0x01e6f0, 0x01e6f4 }, .{ 0x01e6fe, 0x01e6ff }, .{ 0x01e7e0, 0x01e7e6 },
        .{ 0x01e7e8, 0x01e7eb }, .{ 0x01e7ed, 0x01e7ee }, .{ 0x01e7f0, 0x01e7fe },
        .{ 0x01e800, 0x01e8c4 }, .{ 0x01e900, 0x01e943 }, .{ 0x01ee00, 0x01ee03 },
        .{ 0x01ee05, 0x01ee1f }, .{ 0x01ee21, 0x01ee22 }, .{ 0x01ee29, 0x01ee32 },
        .{ 0x01ee34, 0x01ee37 }, .{ 0x01ee4d, 0x01ee4f }, .{ 0x01ee51, 0x01ee52 },
        .{ 0x01ee61, 0x01ee62 }, .{ 0x01ee67, 0x01ee6a }, .{ 0x01ee6c, 0x01ee72 },
        .{ 0x01ee74, 0x01ee77 }, .{ 0x01ee79, 0x01ee7c }, .{ 0x01ee80, 0x01ee89 },
        .{ 0x01ee8b, 0x01ee9b }, .{ 0x01eea1, 0x01eea3 }, .{ 0x01eea5, 0x01eea9 },
        .{ 0x01eeab, 0x01eebb }, .{ 0x020000, 0x02a6df }, .{ 0x02a700, 0x02b81d },
        .{ 0x02b820, 0x02cead }, .{ 0x02ceb0, 0x02ebe0 }, .{ 0x02ebf0, 0x02ee5d },
        .{ 0x02f800, 0x02fa1d }, .{ 0x030000, 0x03134a }, .{ 0x031350, 0x033479 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeOtherLetterCategoryCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000aa, 0x0000ba, 0x0001bb, 0x0006d5, 0x0006ff, 0x000710,
        0x0007b1, 0x00093d, 0x000950, 0x0009b2, 0x0009bd, 0x0009ce,
        0x0009fc, 0x000a5e, 0x000abd, 0x000ad0, 0x000af9, 0x000b3d,
        0x000b71, 0x000b83, 0x000b9c, 0x000bd0, 0x000c3d, 0x000c80,
        0x000cbd, 0x000d3d, 0x000d4e, 0x000dbd, 0x000e84, 0x000ea5,
        0x000ebd, 0x000f00, 0x00103f, 0x001061, 0x00108e, 0x001258,
        0x0012c0, 0x0017dc, 0x0018aa, 0x001cfa, 0x003006, 0x00303c,
        0x00309f, 0x0030ff, 0x00a66e, 0x00a78f, 0x00a7f7, 0x00a8fb,
        0x00aa7a, 0x00aab1, 0x00aac0, 0x00aac2, 0x00aaf2, 0x00fb1d,
        0x00fb3e, 0x010808, 0x01083c, 0x010a00, 0x010d4f, 0x010f27,
        0x011075, 0x011144, 0x011147, 0x011176, 0x0111da, 0x0111dc,
        0x011288, 0x01133d, 0x011350, 0x01138b, 0x01138e, 0x0113b7,
        0x0113d1, 0x0113d3, 0x0114c7, 0x011644, 0x0116b8, 0x011909,
        0x01193f, 0x011941, 0x0119e1, 0x0119e3, 0x011a00, 0x011a3a,
        0x011a50, 0x011a9d, 0x011c40, 0x011d46, 0x011d98, 0x011f02,
        0x011fb0, 0x016f50, 0x01b132, 0x01b155, 0x01df0a, 0x01e14e,
        0x01e5f0, 0x01e6fe, 0x01ee24, 0x01ee27, 0x01ee39, 0x01ee3b,
        0x01ee42, 0x01ee47, 0x01ee49, 0x01ee4b, 0x01ee54, 0x01ee57,
        0x01ee59, 0x01ee5b, 0x01ee5d, 0x01ee5f, 0x01ee64, 0x01ee7e,
    };
    const ranges = [_][2]u21{
        .{ 0x0001c0, 0x0001c3 }, .{ 0x000294, 0x000295 }, .{ 0x0005d0, 0x0005ea },
        .{ 0x0005ef, 0x0005f2 }, .{ 0x000620, 0x00063f }, .{ 0x000641, 0x00064a },
        .{ 0x00066e, 0x00066f }, .{ 0x000671, 0x0006d3 }, .{ 0x0006ee, 0x0006ef },
        .{ 0x0006fa, 0x0006fc }, .{ 0x000712, 0x00072f }, .{ 0x00074d, 0x0007a5 },
        .{ 0x0007ca, 0x0007ea }, .{ 0x000800, 0x000815 }, .{ 0x000840, 0x000858 },
        .{ 0x000860, 0x00086a }, .{ 0x000870, 0x000887 }, .{ 0x000889, 0x00088f },
        .{ 0x0008a0, 0x0008c8 }, .{ 0x000904, 0x000939 }, .{ 0x000958, 0x000961 },
        .{ 0x000972, 0x000980 }, .{ 0x000985, 0x00098c }, .{ 0x00098f, 0x000990 },
        .{ 0x000993, 0x0009a8 }, .{ 0x0009aa, 0x0009b0 }, .{ 0x0009b6, 0x0009b9 },
        .{ 0x0009dc, 0x0009dd }, .{ 0x0009df, 0x0009e1 }, .{ 0x0009f0, 0x0009f1 },
        .{ 0x000a05, 0x000a0a }, .{ 0x000a0f, 0x000a10 }, .{ 0x000a13, 0x000a28 },
        .{ 0x000a2a, 0x000a30 }, .{ 0x000a32, 0x000a33 }, .{ 0x000a35, 0x000a36 },
        .{ 0x000a38, 0x000a39 }, .{ 0x000a59, 0x000a5c }, .{ 0x000a72, 0x000a74 },
        .{ 0x000a85, 0x000a8d }, .{ 0x000a8f, 0x000a91 }, .{ 0x000a93, 0x000aa8 },
        .{ 0x000aaa, 0x000ab0 }, .{ 0x000ab2, 0x000ab3 }, .{ 0x000ab5, 0x000ab9 },
        .{ 0x000ae0, 0x000ae1 }, .{ 0x000b05, 0x000b0c }, .{ 0x000b0f, 0x000b10 },
        .{ 0x000b13, 0x000b28 }, .{ 0x000b2a, 0x000b30 }, .{ 0x000b32, 0x000b33 },
        .{ 0x000b35, 0x000b39 }, .{ 0x000b5c, 0x000b5d }, .{ 0x000b5f, 0x000b61 },
        .{ 0x000b85, 0x000b8a }, .{ 0x000b8e, 0x000b90 }, .{ 0x000b92, 0x000b95 },
        .{ 0x000b99, 0x000b9a }, .{ 0x000b9e, 0x000b9f }, .{ 0x000ba3, 0x000ba4 },
        .{ 0x000ba8, 0x000baa }, .{ 0x000bae, 0x000bb9 }, .{ 0x000c05, 0x000c0c },
        .{ 0x000c0e, 0x000c10 }, .{ 0x000c12, 0x000c28 }, .{ 0x000c2a, 0x000c39 },
        .{ 0x000c58, 0x000c5a }, .{ 0x000c5c, 0x000c5d }, .{ 0x000c60, 0x000c61 },
        .{ 0x000c85, 0x000c8c }, .{ 0x000c8e, 0x000c90 }, .{ 0x000c92, 0x000ca8 },
        .{ 0x000caa, 0x000cb3 }, .{ 0x000cb5, 0x000cb9 }, .{ 0x000cdc, 0x000cde },
        .{ 0x000ce0, 0x000ce1 }, .{ 0x000cf1, 0x000cf2 }, .{ 0x000d04, 0x000d0c },
        .{ 0x000d0e, 0x000d10 }, .{ 0x000d12, 0x000d3a }, .{ 0x000d54, 0x000d56 },
        .{ 0x000d5f, 0x000d61 }, .{ 0x000d7a, 0x000d7f }, .{ 0x000d85, 0x000d96 },
        .{ 0x000d9a, 0x000db1 }, .{ 0x000db3, 0x000dbb }, .{ 0x000dc0, 0x000dc6 },
        .{ 0x000e01, 0x000e30 }, .{ 0x000e32, 0x000e33 }, .{ 0x000e40, 0x000e45 },
        .{ 0x000e81, 0x000e82 }, .{ 0x000e86, 0x000e8a }, .{ 0x000e8c, 0x000ea3 },
        .{ 0x000ea7, 0x000eb0 }, .{ 0x000eb2, 0x000eb3 }, .{ 0x000ec0, 0x000ec4 },
        .{ 0x000edc, 0x000edf }, .{ 0x000f40, 0x000f47 }, .{ 0x000f49, 0x000f6c },
        .{ 0x000f88, 0x000f8c }, .{ 0x001000, 0x00102a }, .{ 0x001050, 0x001055 },
        .{ 0x00105a, 0x00105d }, .{ 0x001065, 0x001066 }, .{ 0x00106e, 0x001070 },
        .{ 0x001075, 0x001081 }, .{ 0x001100, 0x001248 }, .{ 0x00124a, 0x00124d },
        .{ 0x001250, 0x001256 }, .{ 0x00125a, 0x00125d }, .{ 0x001260, 0x001288 },
        .{ 0x00128a, 0x00128d }, .{ 0x001290, 0x0012b0 }, .{ 0x0012b2, 0x0012b5 },
        .{ 0x0012b8, 0x0012be }, .{ 0x0012c2, 0x0012c5 }, .{ 0x0012c8, 0x0012d6 },
        .{ 0x0012d8, 0x001310 }, .{ 0x001312, 0x001315 }, .{ 0x001318, 0x00135a },
        .{ 0x001380, 0x00138f }, .{ 0x001401, 0x00166c }, .{ 0x00166f, 0x00167f },
        .{ 0x001681, 0x00169a }, .{ 0x0016a0, 0x0016ea }, .{ 0x0016f1, 0x0016f8 },
        .{ 0x001700, 0x001711 }, .{ 0x00171f, 0x001731 }, .{ 0x001740, 0x001751 },
        .{ 0x001760, 0x00176c }, .{ 0x00176e, 0x001770 }, .{ 0x001780, 0x0017b3 },
        .{ 0x001820, 0x001842 }, .{ 0x001844, 0x001878 }, .{ 0x001880, 0x001884 },
        .{ 0x001887, 0x0018a8 }, .{ 0x0018b0, 0x0018f5 }, .{ 0x001900, 0x00191e },
        .{ 0x001950, 0x00196d }, .{ 0x001970, 0x001974 }, .{ 0x001980, 0x0019ab },
        .{ 0x0019b0, 0x0019c9 }, .{ 0x001a00, 0x001a16 }, .{ 0x001a20, 0x001a54 },
        .{ 0x001b05, 0x001b33 }, .{ 0x001b45, 0x001b4c }, .{ 0x001b83, 0x001ba0 },
        .{ 0x001bae, 0x001baf }, .{ 0x001bba, 0x001be5 }, .{ 0x001c00, 0x001c23 },
        .{ 0x001c4d, 0x001c4f }, .{ 0x001c5a, 0x001c77 }, .{ 0x001ce9, 0x001cec },
        .{ 0x001cee, 0x001cf3 }, .{ 0x001cf5, 0x001cf6 }, .{ 0x002135, 0x002138 },
        .{ 0x002d30, 0x002d67 }, .{ 0x002d80, 0x002d96 }, .{ 0x002da0, 0x002da6 },
        .{ 0x002da8, 0x002dae }, .{ 0x002db0, 0x002db6 }, .{ 0x002db8, 0x002dbe },
        .{ 0x002dc0, 0x002dc6 }, .{ 0x002dc8, 0x002dce }, .{ 0x002dd0, 0x002dd6 },
        .{ 0x002dd8, 0x002dde }, .{ 0x003041, 0x003096 }, .{ 0x0030a1, 0x0030fa },
        .{ 0x003105, 0x00312f }, .{ 0x003131, 0x00318e }, .{ 0x0031a0, 0x0031bf },
        .{ 0x0031f0, 0x0031ff }, .{ 0x003400, 0x004dbf }, .{ 0x004e00, 0x00a014 },
        .{ 0x00a016, 0x00a48c }, .{ 0x00a4d0, 0x00a4f7 }, .{ 0x00a500, 0x00a60b },
        .{ 0x00a610, 0x00a61f }, .{ 0x00a62a, 0x00a62b }, .{ 0x00a6a0, 0x00a6e5 },
        .{ 0x00a7fb, 0x00a801 }, .{ 0x00a803, 0x00a805 }, .{ 0x00a807, 0x00a80a },
        .{ 0x00a80c, 0x00a822 }, .{ 0x00a840, 0x00a873 }, .{ 0x00a882, 0x00a8b3 },
        .{ 0x00a8f2, 0x00a8f7 }, .{ 0x00a8fd, 0x00a8fe }, .{ 0x00a90a, 0x00a925 },
        .{ 0x00a930, 0x00a946 }, .{ 0x00a960, 0x00a97c }, .{ 0x00a984, 0x00a9b2 },
        .{ 0x00a9e0, 0x00a9e4 }, .{ 0x00a9e7, 0x00a9ef }, .{ 0x00a9fa, 0x00a9fe },
        .{ 0x00aa00, 0x00aa28 }, .{ 0x00aa40, 0x00aa42 }, .{ 0x00aa44, 0x00aa4b },
        .{ 0x00aa60, 0x00aa6f }, .{ 0x00aa71, 0x00aa76 }, .{ 0x00aa7e, 0x00aaaf },
        .{ 0x00aab5, 0x00aab6 }, .{ 0x00aab9, 0x00aabd }, .{ 0x00aadb, 0x00aadc },
        .{ 0x00aae0, 0x00aaea }, .{ 0x00ab01, 0x00ab06 }, .{ 0x00ab09, 0x00ab0e },
        .{ 0x00ab11, 0x00ab16 }, .{ 0x00ab20, 0x00ab26 }, .{ 0x00ab28, 0x00ab2e },
        .{ 0x00abc0, 0x00abe2 }, .{ 0x00ac00, 0x00d7a3 }, .{ 0x00d7b0, 0x00d7c6 },
        .{ 0x00d7cb, 0x00d7fb }, .{ 0x00f900, 0x00fa6d }, .{ 0x00fa70, 0x00fad9 },
        .{ 0x00fb1f, 0x00fb28 }, .{ 0x00fb2a, 0x00fb36 }, .{ 0x00fb38, 0x00fb3c },
        .{ 0x00fb40, 0x00fb41 }, .{ 0x00fb43, 0x00fb44 }, .{ 0x00fb46, 0x00fbb1 },
        .{ 0x00fbd3, 0x00fd3d }, .{ 0x00fd50, 0x00fd8f }, .{ 0x00fd92, 0x00fdc7 },
        .{ 0x00fdf0, 0x00fdfb }, .{ 0x00fe70, 0x00fe74 }, .{ 0x00fe76, 0x00fefc },
        .{ 0x00ff66, 0x00ff6f }, .{ 0x00ff71, 0x00ff9d }, .{ 0x00ffa0, 0x00ffbe },
        .{ 0x00ffc2, 0x00ffc7 }, .{ 0x00ffca, 0x00ffcf }, .{ 0x00ffd2, 0x00ffd7 },
        .{ 0x00ffda, 0x00ffdc }, .{ 0x010000, 0x01000b }, .{ 0x01000d, 0x010026 },
        .{ 0x010028, 0x01003a }, .{ 0x01003c, 0x01003d }, .{ 0x01003f, 0x01004d },
        .{ 0x010050, 0x01005d }, .{ 0x010080, 0x0100fa }, .{ 0x010280, 0x01029c },
        .{ 0x0102a0, 0x0102d0 }, .{ 0x010300, 0x01031f }, .{ 0x01032d, 0x010340 },
        .{ 0x010342, 0x010349 }, .{ 0x010350, 0x010375 }, .{ 0x010380, 0x01039d },
        .{ 0x0103a0, 0x0103c3 }, .{ 0x0103c8, 0x0103cf }, .{ 0x010450, 0x01049d },
        .{ 0x010500, 0x010527 }, .{ 0x010530, 0x010563 }, .{ 0x0105c0, 0x0105f3 },
        .{ 0x010600, 0x010736 }, .{ 0x010740, 0x010755 }, .{ 0x010760, 0x010767 },
        .{ 0x010800, 0x010805 }, .{ 0x01080a, 0x010835 }, .{ 0x010837, 0x010838 },
        .{ 0x01083f, 0x010855 }, .{ 0x010860, 0x010876 }, .{ 0x010880, 0x01089e },
        .{ 0x0108e0, 0x0108f2 }, .{ 0x0108f4, 0x0108f5 }, .{ 0x010900, 0x010915 },
        .{ 0x010920, 0x010939 }, .{ 0x010940, 0x010959 }, .{ 0x010980, 0x0109b7 },
        .{ 0x0109be, 0x0109bf }, .{ 0x010a10, 0x010a13 }, .{ 0x010a15, 0x010a17 },
        .{ 0x010a19, 0x010a35 }, .{ 0x010a60, 0x010a7c }, .{ 0x010a80, 0x010a9c },
        .{ 0x010ac0, 0x010ac7 }, .{ 0x010ac9, 0x010ae4 }, .{ 0x010b00, 0x010b35 },
        .{ 0x010b40, 0x010b55 }, .{ 0x010b60, 0x010b72 }, .{ 0x010b80, 0x010b91 },
        .{ 0x010c00, 0x010c48 }, .{ 0x010d00, 0x010d23 }, .{ 0x010d4a, 0x010d4d },
        .{ 0x010e80, 0x010ea9 }, .{ 0x010eb0, 0x010eb1 }, .{ 0x010ec2, 0x010ec4 },
        .{ 0x010ec6, 0x010ec7 }, .{ 0x010f00, 0x010f1c }, .{ 0x010f30, 0x010f45 },
        .{ 0x010f70, 0x010f81 }, .{ 0x010fb0, 0x010fc4 }, .{ 0x010fe0, 0x010ff6 },
        .{ 0x011003, 0x011037 }, .{ 0x011071, 0x011072 }, .{ 0x011083, 0x0110af },
        .{ 0x0110d0, 0x0110e8 }, .{ 0x011103, 0x011126 }, .{ 0x011150, 0x011172 },
        .{ 0x011183, 0x0111b2 }, .{ 0x0111c1, 0x0111c4 }, .{ 0x011200, 0x011211 },
        .{ 0x011213, 0x01122b }, .{ 0x01123f, 0x011240 }, .{ 0x011280, 0x011286 },
        .{ 0x01128a, 0x01128d }, .{ 0x01128f, 0x01129d }, .{ 0x01129f, 0x0112a8 },
        .{ 0x0112b0, 0x0112de }, .{ 0x011305, 0x01130c }, .{ 0x01130f, 0x011310 },
        .{ 0x011313, 0x011328 }, .{ 0x01132a, 0x011330 }, .{ 0x011332, 0x011333 },
        .{ 0x011335, 0x011339 }, .{ 0x01135d, 0x011361 }, .{ 0x011380, 0x011389 },
        .{ 0x011390, 0x0113b5 }, .{ 0x011400, 0x011434 }, .{ 0x011447, 0x01144a },
        .{ 0x01145f, 0x011461 }, .{ 0x011480, 0x0114af }, .{ 0x0114c4, 0x0114c5 },
        .{ 0x011580, 0x0115ae }, .{ 0x0115d8, 0x0115db }, .{ 0x011600, 0x01162f },
        .{ 0x011680, 0x0116aa }, .{ 0x011700, 0x01171a }, .{ 0x011740, 0x011746 },
        .{ 0x011800, 0x01182b }, .{ 0x0118ff, 0x011906 }, .{ 0x01190c, 0x011913 },
        .{ 0x011915, 0x011916 }, .{ 0x011918, 0x01192f }, .{ 0x0119a0, 0x0119a7 },
        .{ 0x0119aa, 0x0119d0 }, .{ 0x011a0b, 0x011a32 }, .{ 0x011a5c, 0x011a89 },
        .{ 0x011ab0, 0x011af8 }, .{ 0x011bc0, 0x011be0 }, .{ 0x011c00, 0x011c08 },
        .{ 0x011c0a, 0x011c2e }, .{ 0x011c72, 0x011c8f }, .{ 0x011d00, 0x011d06 },
        .{ 0x011d08, 0x011d09 }, .{ 0x011d0b, 0x011d30 }, .{ 0x011d60, 0x011d65 },
        .{ 0x011d67, 0x011d68 }, .{ 0x011d6a, 0x011d89 }, .{ 0x011db0, 0x011dd8 },
        .{ 0x011dda, 0x011ddb }, .{ 0x011ee0, 0x011ef2 }, .{ 0x011f04, 0x011f10 },
        .{ 0x011f12, 0x011f33 }, .{ 0x012000, 0x012399 }, .{ 0x012480, 0x012543 },
        .{ 0x012f90, 0x012ff0 }, .{ 0x013000, 0x01342f }, .{ 0x013441, 0x013446 },
        .{ 0x013460, 0x0143fa }, .{ 0x014400, 0x014646 }, .{ 0x016100, 0x01611d },
        .{ 0x016800, 0x016a38 }, .{ 0x016a40, 0x016a5e }, .{ 0x016a70, 0x016abe },
        .{ 0x016ad0, 0x016aed }, .{ 0x016b00, 0x016b2f }, .{ 0x016b63, 0x016b77 },
        .{ 0x016b7d, 0x016b8f }, .{ 0x016d43, 0x016d6a }, .{ 0x016f00, 0x016f4a },
        .{ 0x017000, 0x018cd5 }, .{ 0x018cff, 0x018d1e }, .{ 0x018d80, 0x018df2 },
        .{ 0x01b000, 0x01b122 }, .{ 0x01b150, 0x01b152 }, .{ 0x01b164, 0x01b167 },
        .{ 0x01b170, 0x01b2fb }, .{ 0x01bc00, 0x01bc6a }, .{ 0x01bc70, 0x01bc7c },
        .{ 0x01bc80, 0x01bc88 }, .{ 0x01bc90, 0x01bc99 }, .{ 0x01e100, 0x01e12c },
        .{ 0x01e290, 0x01e2ad }, .{ 0x01e2c0, 0x01e2eb }, .{ 0x01e4d0, 0x01e4ea },
        .{ 0x01e5d0, 0x01e5ed }, .{ 0x01e6c0, 0x01e6de }, .{ 0x01e6e0, 0x01e6e2 },
        .{ 0x01e6e4, 0x01e6e5 }, .{ 0x01e6e7, 0x01e6ed }, .{ 0x01e6f0, 0x01e6f4 },
        .{ 0x01e7e0, 0x01e7e6 }, .{ 0x01e7e8, 0x01e7eb }, .{ 0x01e7ed, 0x01e7ee },
        .{ 0x01e7f0, 0x01e7fe }, .{ 0x01e800, 0x01e8c4 }, .{ 0x01ee00, 0x01ee03 },
        .{ 0x01ee05, 0x01ee1f }, .{ 0x01ee21, 0x01ee22 }, .{ 0x01ee29, 0x01ee32 },
        .{ 0x01ee34, 0x01ee37 }, .{ 0x01ee4d, 0x01ee4f }, .{ 0x01ee51, 0x01ee52 },
        .{ 0x01ee61, 0x01ee62 }, .{ 0x01ee67, 0x01ee6a }, .{ 0x01ee6c, 0x01ee72 },
        .{ 0x01ee74, 0x01ee77 }, .{ 0x01ee79, 0x01ee7c }, .{ 0x01ee80, 0x01ee89 },
        .{ 0x01ee8b, 0x01ee9b }, .{ 0x01eea1, 0x01eea3 }, .{ 0x01eea5, 0x01eea9 },
        .{ 0x01eeab, 0x01eebb }, .{ 0x020000, 0x02a6df }, .{ 0x02a700, 0x02b81d },
        .{ 0x02b820, 0x02cead }, .{ 0x02ceb0, 0x02ebe0 }, .{ 0x02ebf0, 0x02ee5d },
        .{ 0x02f800, 0x02fa1d }, .{ 0x030000, 0x03134a }, .{ 0x031350, 0x033479 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeUppercaseLetterCategoryCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000100, 0x000102, 0x000104, 0x000106, 0x000108, 0x00010a,
        0x00010c, 0x00010e, 0x000110, 0x000112, 0x000114, 0x000116,
        0x000118, 0x00011a, 0x00011c, 0x00011e, 0x000120, 0x000122,
        0x000124, 0x000126, 0x000128, 0x00012a, 0x00012c, 0x00012e,
        0x000130, 0x000132, 0x000134, 0x000136, 0x000139, 0x00013b,
        0x00013d, 0x00013f, 0x000141, 0x000143, 0x000145, 0x000147,
        0x00014a, 0x00014c, 0x00014e, 0x000150, 0x000152, 0x000154,
        0x000156, 0x000158, 0x00015a, 0x00015c, 0x00015e, 0x000160,
        0x000162, 0x000164, 0x000166, 0x000168, 0x00016a, 0x00016c,
        0x00016e, 0x000170, 0x000172, 0x000174, 0x000176, 0x00017b,
        0x00017d, 0x000184, 0x0001a2, 0x0001a4, 0x0001a9, 0x0001ac,
        0x0001b5, 0x0001bc, 0x0001c4, 0x0001c7, 0x0001ca, 0x0001cd,
        0x0001cf, 0x0001d1, 0x0001d3, 0x0001d5, 0x0001d7, 0x0001d9,
        0x0001db, 0x0001de, 0x0001e0, 0x0001e2, 0x0001e4, 0x0001e6,
        0x0001e8, 0x0001ea, 0x0001ec, 0x0001ee, 0x0001f1, 0x0001f4,
        0x0001fa, 0x0001fc, 0x0001fe, 0x000200, 0x000202, 0x000204,
        0x000206, 0x000208, 0x00020a, 0x00020c, 0x00020e, 0x000210,
        0x000212, 0x000214, 0x000216, 0x000218, 0x00021a, 0x00021c,
        0x00021e, 0x000220, 0x000222, 0x000224, 0x000226, 0x000228,
        0x00022a, 0x00022c, 0x00022e, 0x000230, 0x000232, 0x000241,
        0x000248, 0x00024a, 0x00024c, 0x00024e, 0x000370, 0x000372,
        0x000376, 0x00037f, 0x000386, 0x00038c, 0x0003cf, 0x0003d8,
        0x0003da, 0x0003dc, 0x0003de, 0x0003e0, 0x0003e2, 0x0003e4,
        0x0003e6, 0x0003e8, 0x0003ea, 0x0003ec, 0x0003ee, 0x0003f4,
        0x0003f7, 0x000460, 0x000462, 0x000464, 0x000466, 0x000468,
        0x00046a, 0x00046c, 0x00046e, 0x000470, 0x000472, 0x000474,
        0x000476, 0x000478, 0x00047a, 0x00047c, 0x00047e, 0x000480,
        0x00048a, 0x00048c, 0x00048e, 0x000490, 0x000492, 0x000494,
        0x000496, 0x000498, 0x00049a, 0x00049c, 0x00049e, 0x0004a0,
        0x0004a2, 0x0004a4, 0x0004a6, 0x0004a8, 0x0004aa, 0x0004ac,
        0x0004ae, 0x0004b0, 0x0004b2, 0x0004b4, 0x0004b6, 0x0004b8,
        0x0004ba, 0x0004bc, 0x0004be, 0x0004c3, 0x0004c5, 0x0004c7,
        0x0004c9, 0x0004cb, 0x0004cd, 0x0004d0, 0x0004d2, 0x0004d4,
        0x0004d6, 0x0004d8, 0x0004da, 0x0004dc, 0x0004de, 0x0004e0,
        0x0004e2, 0x0004e4, 0x0004e6, 0x0004e8, 0x0004ea, 0x0004ec,
        0x0004ee, 0x0004f0, 0x0004f2, 0x0004f4, 0x0004f6, 0x0004f8,
        0x0004fa, 0x0004fc, 0x0004fe, 0x000500, 0x000502, 0x000504,
        0x000506, 0x000508, 0x00050a, 0x00050c, 0x00050e, 0x000510,
        0x000512, 0x000514, 0x000516, 0x000518, 0x00051a, 0x00051c,
        0x00051e, 0x000520, 0x000522, 0x000524, 0x000526, 0x000528,
        0x00052a, 0x00052c, 0x00052e, 0x0010c7, 0x0010cd, 0x001c89,
        0x001e00, 0x001e02, 0x001e04, 0x001e06, 0x001e08, 0x001e0a,
        0x001e0c, 0x001e0e, 0x001e10, 0x001e12, 0x001e14, 0x001e16,
        0x001e18, 0x001e1a, 0x001e1c, 0x001e1e, 0x001e20, 0x001e22,
        0x001e24, 0x001e26, 0x001e28, 0x001e2a, 0x001e2c, 0x001e2e,
        0x001e30, 0x001e32, 0x001e34, 0x001e36, 0x001e38, 0x001e3a,
        0x001e3c, 0x001e3e, 0x001e40, 0x001e42, 0x001e44, 0x001e46,
        0x001e48, 0x001e4a, 0x001e4c, 0x001e4e, 0x001e50, 0x001e52,
        0x001e54, 0x001e56, 0x001e58, 0x001e5a, 0x001e5c, 0x001e5e,
        0x001e60, 0x001e62, 0x001e64, 0x001e66, 0x001e68, 0x001e6a,
        0x001e6c, 0x001e6e, 0x001e70, 0x001e72, 0x001e74, 0x001e76,
        0x001e78, 0x001e7a, 0x001e7c, 0x001e7e, 0x001e80, 0x001e82,
        0x001e84, 0x001e86, 0x001e88, 0x001e8a, 0x001e8c, 0x001e8e,
        0x001e90, 0x001e92, 0x001e94, 0x001e9e, 0x001ea0, 0x001ea2,
        0x001ea4, 0x001ea6, 0x001ea8, 0x001eaa, 0x001eac, 0x001eae,
        0x001eb0, 0x001eb2, 0x001eb4, 0x001eb6, 0x001eb8, 0x001eba,
        0x001ebc, 0x001ebe, 0x001ec0, 0x001ec2, 0x001ec4, 0x001ec6,
        0x001ec8, 0x001eca, 0x001ecc, 0x001ece, 0x001ed0, 0x001ed2,
        0x001ed4, 0x001ed6, 0x001ed8, 0x001eda, 0x001edc, 0x001ede,
        0x001ee0, 0x001ee2, 0x001ee4, 0x001ee6, 0x001ee8, 0x001eea,
        0x001eec, 0x001eee, 0x001ef0, 0x001ef2, 0x001ef4, 0x001ef6,
        0x001ef8, 0x001efa, 0x001efc, 0x001efe, 0x001f59, 0x001f5b,
        0x001f5d, 0x001f5f, 0x002102, 0x002107, 0x002115, 0x002124,
        0x002126, 0x002128, 0x002145, 0x002183, 0x002c60, 0x002c67,
        0x002c69, 0x002c6b, 0x002c72, 0x002c75, 0x002c82, 0x002c84,
        0x002c86, 0x002c88, 0x002c8a, 0x002c8c, 0x002c8e, 0x002c90,
        0x002c92, 0x002c94, 0x002c96, 0x002c98, 0x002c9a, 0x002c9c,
        0x002c9e, 0x002ca0, 0x002ca2, 0x002ca4, 0x002ca6, 0x002ca8,
        0x002caa, 0x002cac, 0x002cae, 0x002cb0, 0x002cb2, 0x002cb4,
        0x002cb6, 0x002cb8, 0x002cba, 0x002cbc, 0x002cbe, 0x002cc0,
        0x002cc2, 0x002cc4, 0x002cc6, 0x002cc8, 0x002cca, 0x002ccc,
        0x002cce, 0x002cd0, 0x002cd2, 0x002cd4, 0x002cd6, 0x002cd8,
        0x002cda, 0x002cdc, 0x002cde, 0x002ce0, 0x002ce2, 0x002ceb,
        0x002ced, 0x002cf2, 0x00a640, 0x00a642, 0x00a644, 0x00a646,
        0x00a648, 0x00a64a, 0x00a64c, 0x00a64e, 0x00a650, 0x00a652,
        0x00a654, 0x00a656, 0x00a658, 0x00a65a, 0x00a65c, 0x00a65e,
        0x00a660, 0x00a662, 0x00a664, 0x00a666, 0x00a668, 0x00a66a,
        0x00a66c, 0x00a680, 0x00a682, 0x00a684, 0x00a686, 0x00a688,
        0x00a68a, 0x00a68c, 0x00a68e, 0x00a690, 0x00a692, 0x00a694,
        0x00a696, 0x00a698, 0x00a69a, 0x00a722, 0x00a724, 0x00a726,
        0x00a728, 0x00a72a, 0x00a72c, 0x00a72e, 0x00a732, 0x00a734,
        0x00a736, 0x00a738, 0x00a73a, 0x00a73c, 0x00a73e, 0x00a740,
        0x00a742, 0x00a744, 0x00a746, 0x00a748, 0x00a74a, 0x00a74c,
        0x00a74e, 0x00a750, 0x00a752, 0x00a754, 0x00a756, 0x00a758,
        0x00a75a, 0x00a75c, 0x00a75e, 0x00a760, 0x00a762, 0x00a764,
        0x00a766, 0x00a768, 0x00a76a, 0x00a76c, 0x00a76e, 0x00a779,
        0x00a77b, 0x00a780, 0x00a782, 0x00a784, 0x00a786, 0x00a78b,
        0x00a78d, 0x00a790, 0x00a792, 0x00a796, 0x00a798, 0x00a79a,
        0x00a79c, 0x00a79e, 0x00a7a0, 0x00a7a2, 0x00a7a4, 0x00a7a6,
        0x00a7a8, 0x00a7b6, 0x00a7b8, 0x00a7ba, 0x00a7bc, 0x00a7be,
        0x00a7c0, 0x00a7c2, 0x00a7c9, 0x00a7ce, 0x00a7d0, 0x00a7d2,
        0x00a7d4, 0x00a7d6, 0x00a7d8, 0x00a7da, 0x00a7dc, 0x00a7f5,
        0x01d49c, 0x01d4a2, 0x01d546, 0x01d7ca,
    };
    const ranges = [_][2]u21{
        .{ 0x000041, 0x00005a }, .{ 0x0000c0, 0x0000d6 }, .{ 0x0000d8, 0x0000de },
        .{ 0x000178, 0x000179 }, .{ 0x000181, 0x000182 }, .{ 0x000186, 0x000187 },
        .{ 0x000189, 0x00018b }, .{ 0x00018e, 0x000191 }, .{ 0x000193, 0x000194 },
        .{ 0x000196, 0x000198 }, .{ 0x00019c, 0x00019d }, .{ 0x00019f, 0x0001a0 },
        .{ 0x0001a6, 0x0001a7 }, .{ 0x0001ae, 0x0001af }, .{ 0x0001b1, 0x0001b3 },
        .{ 0x0001b7, 0x0001b8 }, .{ 0x0001f6, 0x0001f8 }, .{ 0x00023a, 0x00023b },
        .{ 0x00023d, 0x00023e }, .{ 0x000243, 0x000246 }, .{ 0x000388, 0x00038a },
        .{ 0x00038e, 0x00038f }, .{ 0x000391, 0x0003a1 }, .{ 0x0003a3, 0x0003ab },
        .{ 0x0003d2, 0x0003d4 }, .{ 0x0003f9, 0x0003fa }, .{ 0x0003fd, 0x00042f },
        .{ 0x0004c0, 0x0004c1 }, .{ 0x000531, 0x000556 }, .{ 0x0010a0, 0x0010c5 },
        .{ 0x0013a0, 0x0013f5 }, .{ 0x001c90, 0x001cba }, .{ 0x001cbd, 0x001cbf },
        .{ 0x001f08, 0x001f0f }, .{ 0x001f18, 0x001f1d }, .{ 0x001f28, 0x001f2f },
        .{ 0x001f38, 0x001f3f }, .{ 0x001f48, 0x001f4d }, .{ 0x001f68, 0x001f6f },
        .{ 0x001fb8, 0x001fbb }, .{ 0x001fc8, 0x001fcb }, .{ 0x001fd8, 0x001fdb },
        .{ 0x001fe8, 0x001fec }, .{ 0x001ff8, 0x001ffb }, .{ 0x00210b, 0x00210d },
        .{ 0x002110, 0x002112 }, .{ 0x002119, 0x00211d }, .{ 0x00212a, 0x00212d },
        .{ 0x002130, 0x002133 }, .{ 0x00213e, 0x00213f }, .{ 0x002c00, 0x002c2f },
        .{ 0x002c62, 0x002c64 }, .{ 0x002c6d, 0x002c70 }, .{ 0x002c7e, 0x002c80 },
        .{ 0x00a77d, 0x00a77e }, .{ 0x00a7aa, 0x00a7ae }, .{ 0x00a7b0, 0x00a7b4 },
        .{ 0x00a7c4, 0x00a7c7 }, .{ 0x00a7cb, 0x00a7cc }, .{ 0x00ff21, 0x00ff3a },
        .{ 0x010400, 0x010427 }, .{ 0x0104b0, 0x0104d3 }, .{ 0x010570, 0x01057a },
        .{ 0x01057c, 0x01058a }, .{ 0x01058c, 0x010592 }, .{ 0x010594, 0x010595 },
        .{ 0x010c80, 0x010cb2 }, .{ 0x010d50, 0x010d65 }, .{ 0x0118a0, 0x0118bf },
        .{ 0x016e40, 0x016e5f }, .{ 0x016ea0, 0x016eb8 }, .{ 0x01d400, 0x01d419 },
        .{ 0x01d434, 0x01d44d }, .{ 0x01d468, 0x01d481 }, .{ 0x01d49e, 0x01d49f },
        .{ 0x01d4a5, 0x01d4a6 }, .{ 0x01d4a9, 0x01d4ac }, .{ 0x01d4ae, 0x01d4b5 },
        .{ 0x01d4d0, 0x01d4e9 }, .{ 0x01d504, 0x01d505 }, .{ 0x01d507, 0x01d50a },
        .{ 0x01d50d, 0x01d514 }, .{ 0x01d516, 0x01d51c }, .{ 0x01d538, 0x01d539 },
        .{ 0x01d53b, 0x01d53e }, .{ 0x01d540, 0x01d544 }, .{ 0x01d54a, 0x01d550 },
        .{ 0x01d56c, 0x01d585 }, .{ 0x01d5a0, 0x01d5b9 }, .{ 0x01d5d4, 0x01d5ed },
        .{ 0x01d608, 0x01d621 }, .{ 0x01d63c, 0x01d655 }, .{ 0x01d670, 0x01d689 },
        .{ 0x01d6a8, 0x01d6c0 }, .{ 0x01d6e2, 0x01d6fa }, .{ 0x01d71c, 0x01d734 },
        .{ 0x01d756, 0x01d76e }, .{ 0x01d790, 0x01d7a8 }, .{ 0x01e900, 0x01e921 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodePunctuationCategoryCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00005f, 0x00007b, 0x00007d, 0x0000a1, 0x0000a7, 0x0000ab,
        0x0000bb, 0x0000bf, 0x00037e, 0x000387, 0x0005be, 0x0005c0,
        0x0005c3, 0x0005c6, 0x00061b, 0x0006d4, 0x00085e, 0x000970,
        0x0009fd, 0x000a76, 0x000af0, 0x000c77, 0x000c84, 0x000df4,
        0x000e4f, 0x000f14, 0x000f85, 0x0010fb, 0x001400, 0x00166e,
        0x001cd3, 0x002d70, 0x003030, 0x00303d, 0x0030a0, 0x0030fb,
        0x00a673, 0x00a67e, 0x00a8fc, 0x00a95f, 0x00abeb, 0x00fe63,
        0x00fe68, 0x00ff3f, 0x00ff5b, 0x00ff5d, 0x01039f, 0x0103d0,
        0x01056f, 0x010857, 0x01091f, 0x01093f, 0x010a7f, 0x010d6e,
        0x010ead, 0x010ed0, 0x0111cd, 0x0111db, 0x0112a9, 0x01145d,
        0x0114c6, 0x0116b9, 0x01183b, 0x0119e2, 0x011be1, 0x011fff,
        0x016af5, 0x016b44, 0x016fe2, 0x01bc9f, 0x01e5ff,
    };
    const ranges = [_][2]u21{
        .{ 0x000021, 0x000023 }, .{ 0x000025, 0x00002a }, .{ 0x00002c, 0x00002f },
        .{ 0x00003a, 0x00003b }, .{ 0x00003f, 0x000040 }, .{ 0x00005b, 0x00005d },
        .{ 0x0000b6, 0x0000b7 }, .{ 0x00055a, 0x00055f }, .{ 0x000589, 0x00058a },
        .{ 0x0005f3, 0x0005f4 }, .{ 0x000609, 0x00060a }, .{ 0x00060c, 0x00060d },
        .{ 0x00061d, 0x00061f }, .{ 0x00066a, 0x00066d }, .{ 0x000700, 0x00070d },
        .{ 0x0007f7, 0x0007f9 }, .{ 0x000830, 0x00083e }, .{ 0x000964, 0x000965 },
        .{ 0x000e5a, 0x000e5b }, .{ 0x000f04, 0x000f12 }, .{ 0x000f3a, 0x000f3d },
        .{ 0x000fd0, 0x000fd4 }, .{ 0x000fd9, 0x000fda }, .{ 0x00104a, 0x00104f },
        .{ 0x001360, 0x001368 }, .{ 0x00169b, 0x00169c }, .{ 0x0016eb, 0x0016ed },
        .{ 0x001735, 0x001736 }, .{ 0x0017d4, 0x0017d6 }, .{ 0x0017d8, 0x0017da },
        .{ 0x001800, 0x00180a }, .{ 0x001944, 0x001945 }, .{ 0x001a1e, 0x001a1f },
        .{ 0x001aa0, 0x001aa6 }, .{ 0x001aa8, 0x001aad }, .{ 0x001b4e, 0x001b4f },
        .{ 0x001b5a, 0x001b60 }, .{ 0x001b7d, 0x001b7f }, .{ 0x001bfc, 0x001bff },
        .{ 0x001c3b, 0x001c3f }, .{ 0x001c7e, 0x001c7f }, .{ 0x001cc0, 0x001cc7 },
        .{ 0x002010, 0x002027 }, .{ 0x002030, 0x002043 }, .{ 0x002045, 0x002051 },
        .{ 0x002053, 0x00205e }, .{ 0x00207d, 0x00207e }, .{ 0x00208d, 0x00208e },
        .{ 0x002308, 0x00230b }, .{ 0x002329, 0x00232a }, .{ 0x002768, 0x002775 },
        .{ 0x0027c5, 0x0027c6 }, .{ 0x0027e6, 0x0027ef }, .{ 0x002983, 0x002998 },
        .{ 0x0029d8, 0x0029db }, .{ 0x0029fc, 0x0029fd }, .{ 0x002cf9, 0x002cfc },
        .{ 0x002cfe, 0x002cff }, .{ 0x002e00, 0x002e2e }, .{ 0x002e30, 0x002e4f },
        .{ 0x002e52, 0x002e5d }, .{ 0x003001, 0x003003 }, .{ 0x003008, 0x003011 },
        .{ 0x003014, 0x00301f }, .{ 0x00a4fe, 0x00a4ff }, .{ 0x00a60d, 0x00a60f },
        .{ 0x00a6f2, 0x00a6f7 }, .{ 0x00a874, 0x00a877 }, .{ 0x00a8ce, 0x00a8cf },
        .{ 0x00a8f8, 0x00a8fa }, .{ 0x00a92e, 0x00a92f }, .{ 0x00a9c1, 0x00a9cd },
        .{ 0x00a9de, 0x00a9df }, .{ 0x00aa5c, 0x00aa5f }, .{ 0x00aade, 0x00aadf },
        .{ 0x00aaf0, 0x00aaf1 }, .{ 0x00fd3e, 0x00fd3f }, .{ 0x00fe10, 0x00fe19 },
        .{ 0x00fe30, 0x00fe52 }, .{ 0x00fe54, 0x00fe61 }, .{ 0x00fe6a, 0x00fe6b },
        .{ 0x00ff01, 0x00ff03 }, .{ 0x00ff05, 0x00ff0a }, .{ 0x00ff0c, 0x00ff0f },
        .{ 0x00ff1a, 0x00ff1b }, .{ 0x00ff1f, 0x00ff20 }, .{ 0x00ff3b, 0x00ff3d },
        .{ 0x00ff5f, 0x00ff65 }, .{ 0x010100, 0x010102 }, .{ 0x010a50, 0x010a58 },
        .{ 0x010af0, 0x010af6 }, .{ 0x010b39, 0x010b3f }, .{ 0x010b99, 0x010b9c },
        .{ 0x010f55, 0x010f59 }, .{ 0x010f86, 0x010f89 }, .{ 0x011047, 0x01104d },
        .{ 0x0110bb, 0x0110bc }, .{ 0x0110be, 0x0110c1 }, .{ 0x011140, 0x011143 },
        .{ 0x011174, 0x011175 }, .{ 0x0111c5, 0x0111c8 }, .{ 0x0111dd, 0x0111df },
        .{ 0x011238, 0x01123d }, .{ 0x0113d4, 0x0113d5 }, .{ 0x0113d7, 0x0113d8 },
        .{ 0x01144b, 0x01144f }, .{ 0x01145a, 0x01145b }, .{ 0x0115c1, 0x0115d7 },
        .{ 0x011641, 0x011643 }, .{ 0x011660, 0x01166c }, .{ 0x01173c, 0x01173e },
        .{ 0x011944, 0x011946 }, .{ 0x011a3f, 0x011a46 }, .{ 0x011a9a, 0x011a9c },
        .{ 0x011a9e, 0x011aa2 }, .{ 0x011b00, 0x011b09 }, .{ 0x011c41, 0x011c45 },
        .{ 0x011c70, 0x011c71 }, .{ 0x011ef7, 0x011ef8 }, .{ 0x011f43, 0x011f4f },
        .{ 0x012470, 0x012474 }, .{ 0x012ff1, 0x012ff2 }, .{ 0x016a6e, 0x016a6f },
        .{ 0x016b37, 0x016b3b }, .{ 0x016d6d, 0x016d6f }, .{ 0x016e97, 0x016e9a },
        .{ 0x01da87, 0x01da8b }, .{ 0x01e95e, 0x01e95f },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeSymbolCategoryCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000024, 0x00002b, 0x00005e, 0x000060, 0x00007c, 0x00007e,
        0x0000ac, 0x0000b4, 0x0000b8, 0x0000d7, 0x0000f7, 0x0002ed,
        0x000375, 0x0003f6, 0x000482, 0x00060b, 0x0006de, 0x0006e9,
        0x0007f6, 0x000888, 0x000af1, 0x000b70, 0x000c7f, 0x000d4f,
        0x000d79, 0x000e3f, 0x000f13, 0x000f34, 0x000f36, 0x000f38,
        0x00166d, 0x0017db, 0x001940, 0x001fbd, 0x002044, 0x002052,
        0x002114, 0x002125, 0x002127, 0x002129, 0x00212e, 0x00214f,
        0x003004, 0x003020, 0x0031ef, 0x003250, 0x00ab5b, 0x00fb29,
        0x00fe62, 0x00fe69, 0x00ff04, 0x00ff0b, 0x00ff3e, 0x00ff40,
        0x00ff5c, 0x00ff5e, 0x0101a0, 0x010ac8, 0x01173f, 0x016b45,
        0x01bc9c, 0x01d245, 0x01d6c1, 0x01d6db, 0x01d6fb, 0x01d715,
        0x01d735, 0x01d74f, 0x01d76f, 0x01d789, 0x01d7a9, 0x01d7c3,
        0x01e14f, 0x01e2ff, 0x01ecac, 0x01ecb0, 0x01ed2e, 0x01f7f0,
        0x01fac8, 0x01fbfa,
    };
    const ranges = [_][2]u21{
        .{ 0x00003c, 0x00003e }, .{ 0x0000a2, 0x0000a6 }, .{ 0x0000a8, 0x0000a9 },
        .{ 0x0000ae, 0x0000b1 }, .{ 0x0002c2, 0x0002c5 }, .{ 0x0002d2, 0x0002df },
        .{ 0x0002e5, 0x0002eb }, .{ 0x0002ef, 0x0002ff }, .{ 0x000384, 0x000385 },
        .{ 0x00058d, 0x00058f }, .{ 0x000606, 0x000608 }, .{ 0x00060e, 0x00060f },
        .{ 0x0006fd, 0x0006fe }, .{ 0x0007fe, 0x0007ff }, .{ 0x0009f2, 0x0009f3 },
        .{ 0x0009fa, 0x0009fb }, .{ 0x000bf3, 0x000bfa }, .{ 0x000f01, 0x000f03 },
        .{ 0x000f15, 0x000f17 }, .{ 0x000f1a, 0x000f1f }, .{ 0x000fbe, 0x000fc5 },
        .{ 0x000fc7, 0x000fcc }, .{ 0x000fce, 0x000fcf }, .{ 0x000fd5, 0x000fd8 },
        .{ 0x00109e, 0x00109f }, .{ 0x001390, 0x001399 }, .{ 0x0019de, 0x0019ff },
        .{ 0x001b61, 0x001b6a }, .{ 0x001b74, 0x001b7c }, .{ 0x001fbf, 0x001fc1 },
        .{ 0x001fcd, 0x001fcf }, .{ 0x001fdd, 0x001fdf }, .{ 0x001fed, 0x001fef },
        .{ 0x001ffd, 0x001ffe }, .{ 0x00207a, 0x00207c }, .{ 0x00208a, 0x00208c },
        .{ 0x0020a0, 0x0020c1 }, .{ 0x002100, 0x002101 }, .{ 0x002103, 0x002106 },
        .{ 0x002108, 0x002109 }, .{ 0x002116, 0x002118 }, .{ 0x00211e, 0x002123 },
        .{ 0x00213a, 0x00213b }, .{ 0x002140, 0x002144 }, .{ 0x00214a, 0x00214d },
        .{ 0x00218a, 0x00218b }, .{ 0x002190, 0x002307 }, .{ 0x00230c, 0x002328 },
        .{ 0x00232b, 0x002429 }, .{ 0x002440, 0x00244a }, .{ 0x00249c, 0x0024e9 },
        .{ 0x002500, 0x002767 }, .{ 0x002794, 0x0027c4 }, .{ 0x0027c7, 0x0027e5 },
        .{ 0x0027f0, 0x002982 }, .{ 0x002999, 0x0029d7 }, .{ 0x0029dc, 0x0029fb },
        .{ 0x0029fe, 0x002b73 }, .{ 0x002b76, 0x002bff }, .{ 0x002ce5, 0x002cea },
        .{ 0x002e50, 0x002e51 }, .{ 0x002e80, 0x002e99 }, .{ 0x002e9b, 0x002ef3 },
        .{ 0x002f00, 0x002fd5 }, .{ 0x002ff0, 0x002fff }, .{ 0x003012, 0x003013 },
        .{ 0x003036, 0x003037 }, .{ 0x00303e, 0x00303f }, .{ 0x00309b, 0x00309c },
        .{ 0x003190, 0x003191 }, .{ 0x003196, 0x00319f }, .{ 0x0031c0, 0x0031e5 },
        .{ 0x003200, 0x00321e }, .{ 0x00322a, 0x003247 }, .{ 0x003260, 0x00327f },
        .{ 0x00328a, 0x0032b0 }, .{ 0x0032c0, 0x0033ff }, .{ 0x004dc0, 0x004dff },
        .{ 0x00a490, 0x00a4c6 }, .{ 0x00a700, 0x00a716 }, .{ 0x00a720, 0x00a721 },
        .{ 0x00a789, 0x00a78a }, .{ 0x00a828, 0x00a82b }, .{ 0x00a836, 0x00a839 },
        .{ 0x00aa77, 0x00aa79 }, .{ 0x00ab6a, 0x00ab6b }, .{ 0x00fbb2, 0x00fbd2 },
        .{ 0x00fd40, 0x00fd4f }, .{ 0x00fd90, 0x00fd91 }, .{ 0x00fdc8, 0x00fdcf },
        .{ 0x00fdfc, 0x00fdff }, .{ 0x00fe64, 0x00fe66 }, .{ 0x00ff1c, 0x00ff1e },
        .{ 0x00ffe0, 0x00ffe6 }, .{ 0x00ffe8, 0x00ffee }, .{ 0x00fffc, 0x00fffd },
        .{ 0x010137, 0x01013f }, .{ 0x010179, 0x010189 }, .{ 0x01018c, 0x01018e },
        .{ 0x010190, 0x01019c }, .{ 0x0101d0, 0x0101fc }, .{ 0x010877, 0x010878 },
        .{ 0x010d8e, 0x010d8f }, .{ 0x010ed1, 0x010ed8 }, .{ 0x011fd5, 0x011ff1 },
        .{ 0x016b3c, 0x016b3f }, .{ 0x01cc00, 0x01ccef }, .{ 0x01ccfa, 0x01ccfc },
        .{ 0x01cd00, 0x01ceb3 }, .{ 0x01ceba, 0x01ced0 }, .{ 0x01cee0, 0x01cef0 },
        .{ 0x01cf50, 0x01cfc3 }, .{ 0x01d000, 0x01d0f5 }, .{ 0x01d100, 0x01d126 },
        .{ 0x01d129, 0x01d164 }, .{ 0x01d16a, 0x01d16c }, .{ 0x01d183, 0x01d184 },
        .{ 0x01d18c, 0x01d1a9 }, .{ 0x01d1ae, 0x01d1ea }, .{ 0x01d200, 0x01d241 },
        .{ 0x01d300, 0x01d356 }, .{ 0x01d800, 0x01d9ff }, .{ 0x01da37, 0x01da3a },
        .{ 0x01da6d, 0x01da74 }, .{ 0x01da76, 0x01da83 }, .{ 0x01da85, 0x01da86 },
        .{ 0x01eef0, 0x01eef1 }, .{ 0x01f000, 0x01f02b }, .{ 0x01f030, 0x01f093 },
        .{ 0x01f0a0, 0x01f0ae }, .{ 0x01f0b1, 0x01f0bf }, .{ 0x01f0c1, 0x01f0cf },
        .{ 0x01f0d1, 0x01f0f5 }, .{ 0x01f10d, 0x01f1ad }, .{ 0x01f1e6, 0x01f202 },
        .{ 0x01f210, 0x01f23b }, .{ 0x01f240, 0x01f248 }, .{ 0x01f250, 0x01f251 },
        .{ 0x01f260, 0x01f265 }, .{ 0x01f300, 0x01f6d8 }, .{ 0x01f6dc, 0x01f6ec },
        .{ 0x01f6f0, 0x01f6fc }, .{ 0x01f700, 0x01f7d9 }, .{ 0x01f7e0, 0x01f7eb },
        .{ 0x01f800, 0x01f80b }, .{ 0x01f810, 0x01f847 }, .{ 0x01f850, 0x01f859 },
        .{ 0x01f860, 0x01f887 }, .{ 0x01f890, 0x01f8ad }, .{ 0x01f8b0, 0x01f8bb },
        .{ 0x01f8c0, 0x01f8c1 }, .{ 0x01f8d0, 0x01f8d8 }, .{ 0x01f900, 0x01fa57 },
        .{ 0x01fa60, 0x01fa6d }, .{ 0x01fa70, 0x01fa7c }, .{ 0x01fa80, 0x01fa8a },
        .{ 0x01fa8e, 0x01fac6 }, .{ 0x01facd, 0x01fadc }, .{ 0x01fadf, 0x01faea },
        .{ 0x01faef, 0x01faf8 }, .{ 0x01fb00, 0x01fb92 }, .{ 0x01fb94, 0x01fbef },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}

pub fn isUnicodeGraphemeBaseCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00038c, 0x0005be, 0x0005c0, 0x0005c3, 0x0005c6, 0x00061b, 0x0006de, 0x0006e9,
        0x000710, 0x0007b1, 0x00081a, 0x000824, 0x000828, 0x00085e, 0x00093b, 0x0009b2,
        0x0009bd, 0x0009ce, 0x000a03, 0x000a5e, 0x000a76, 0x000a83, 0x000ac9, 0x000ad0,
        0x000af9, 0x000b3d, 0x000b40, 0x000b83, 0x000b9c, 0x000bbf, 0x000bd0, 0x000c3d,
        0x000cc1, 0x000d3d, 0x000dbd, 0x000e84, 0x000ea5, 0x000ebd, 0x000ec6, 0x000f36,
        0x000f38, 0x000f7f, 0x000f85, 0x001031, 0x001038, 0x0010c7, 0x0010cd, 0x001258,
        0x0012c0, 0x0017b6, 0x0018aa, 0x001940, 0x001a57, 0x001a61, 0x001be7, 0x001bee,
        0x001cd3, 0x001ce1, 0x001cfa, 0x001f59, 0x001f5b, 0x001f5d, 0x002d27, 0x002d2d,
        0x00a673, 0x00a952, 0x00aa4d, 0x00aab1, 0x00aac0, 0x00aac2, 0x00fb1d, 0x00fb3e,
        0x0101a0, 0x010808, 0x01083c, 0x010ead, 0x011000, 0x011075, 0x01112c, 0x0111bf,
        0x011288, 0x01133d, 0x01133f, 0x011350, 0x01138b, 0x01138e, 0x0113b7, 0x0113ca,
        0x0113d1, 0x011445, 0x01145d, 0x0114b9, 0x0114be, 0x0114c1, 0x0115be, 0x01163e,
        0x0116ac, 0x01171e, 0x011726, 0x011838, 0x01183b, 0x011909, 0x011a00, 0x011a50,
        0x011a97, 0x011b61, 0x011b65, 0x011b67, 0x011c3e, 0x011ca9, 0x011cb1, 0x011cb4,
        0x011d46, 0x011d96, 0x011d98, 0x011fb0, 0x016af5, 0x01b132, 0x01b155, 0x01bc9c,
        0x01bc9f, 0x01d245, 0x01d4a2, 0x01d4bb, 0x01d546, 0x01e2ff, 0x01e5ff, 0x01e94b,
        0x01ee24, 0x01ee27, 0x01ee39, 0x01ee3b, 0x01ee42, 0x01ee47, 0x01ee49, 0x01ee4b,
        0x01ee54, 0x01ee57, 0x01ee59, 0x01ee5b, 0x01ee5d, 0x01ee5f, 0x01ee64, 0x01ee7e,
        0x01f7f0, 0x01fac8,
    };
    const ranges = [_][2]u21{
        .{ 0x000020, 0x00007e }, .{ 0x0000a0, 0x0000ac }, .{ 0x0000ae, 0x0002ff },
        .{ 0x000370, 0x000377 }, .{ 0x00037a, 0x00037f }, .{ 0x000384, 0x00038a },
        .{ 0x00038e, 0x0003a1 }, .{ 0x0003a3, 0x000482 }, .{ 0x00048a, 0x00052f },
        .{ 0x000531, 0x000556 }, .{ 0x000559, 0x00058a }, .{ 0x00058d, 0x00058f },
        .{ 0x0005d0, 0x0005ea }, .{ 0x0005ef, 0x0005f4 }, .{ 0x000606, 0x00060f },
        .{ 0x00061d, 0x00064a }, .{ 0x000660, 0x00066f }, .{ 0x000671, 0x0006d5 },
        .{ 0x0006e5, 0x0006e6 }, .{ 0x0006ee, 0x00070d }, .{ 0x000712, 0x00072f },
        .{ 0x00074d, 0x0007a5 }, .{ 0x0007c0, 0x0007ea }, .{ 0x0007f4, 0x0007fa },
        .{ 0x0007fe, 0x000815 }, .{ 0x000830, 0x00083e }, .{ 0x000840, 0x000858 },
        .{ 0x000860, 0x00086a }, .{ 0x000870, 0x00088f }, .{ 0x0008a0, 0x0008c9 },
        .{ 0x000903, 0x000939 }, .{ 0x00093d, 0x000940 }, .{ 0x000949, 0x00094c },
        .{ 0x00094e, 0x000950 }, .{ 0x000958, 0x000961 }, .{ 0x000964, 0x000980 },
        .{ 0x000982, 0x000983 }, .{ 0x000985, 0x00098c }, .{ 0x00098f, 0x000990 },
        .{ 0x000993, 0x0009a8 }, .{ 0x0009aa, 0x0009b0 }, .{ 0x0009b6, 0x0009b9 },
        .{ 0x0009bf, 0x0009c0 }, .{ 0x0009c7, 0x0009c8 }, .{ 0x0009cb, 0x0009cc },
        .{ 0x0009dc, 0x0009dd }, .{ 0x0009df, 0x0009e1 }, .{ 0x0009e6, 0x0009fd },
        .{ 0x000a05, 0x000a0a }, .{ 0x000a0f, 0x000a10 }, .{ 0x000a13, 0x000a28 },
        .{ 0x000a2a, 0x000a30 }, .{ 0x000a32, 0x000a33 }, .{ 0x000a35, 0x000a36 },
        .{ 0x000a38, 0x000a39 }, .{ 0x000a3e, 0x000a40 }, .{ 0x000a59, 0x000a5c },
        .{ 0x000a66, 0x000a6f }, .{ 0x000a72, 0x000a74 }, .{ 0x000a85, 0x000a8d },
        .{ 0x000a8f, 0x000a91 }, .{ 0x000a93, 0x000aa8 }, .{ 0x000aaa, 0x000ab0 },
        .{ 0x000ab2, 0x000ab3 }, .{ 0x000ab5, 0x000ab9 }, .{ 0x000abd, 0x000ac0 },
        .{ 0x000acb, 0x000acc }, .{ 0x000ae0, 0x000ae1 }, .{ 0x000ae6, 0x000af1 },
        .{ 0x000b02, 0x000b03 }, .{ 0x000b05, 0x000b0c }, .{ 0x000b0f, 0x000b10 },
        .{ 0x000b13, 0x000b28 }, .{ 0x000b2a, 0x000b30 }, .{ 0x000b32, 0x000b33 },
        .{ 0x000b35, 0x000b39 }, .{ 0x000b47, 0x000b48 }, .{ 0x000b4b, 0x000b4c },
        .{ 0x000b5c, 0x000b5d }, .{ 0x000b5f, 0x000b61 }, .{ 0x000b66, 0x000b77 },
        .{ 0x000b85, 0x000b8a }, .{ 0x000b8e, 0x000b90 }, .{ 0x000b92, 0x000b95 },
        .{ 0x000b99, 0x000b9a }, .{ 0x000b9e, 0x000b9f }, .{ 0x000ba3, 0x000ba4 },
        .{ 0x000ba8, 0x000baa }, .{ 0x000bae, 0x000bb9 }, .{ 0x000bc1, 0x000bc2 },
        .{ 0x000bc6, 0x000bc8 }, .{ 0x000bca, 0x000bcc }, .{ 0x000be6, 0x000bfa },
        .{ 0x000c01, 0x000c03 }, .{ 0x000c05, 0x000c0c }, .{ 0x000c0e, 0x000c10 },
        .{ 0x000c12, 0x000c28 }, .{ 0x000c2a, 0x000c39 }, .{ 0x000c41, 0x000c44 },
        .{ 0x000c58, 0x000c5a }, .{ 0x000c5c, 0x000c5d }, .{ 0x000c60, 0x000c61 },
        .{ 0x000c66, 0x000c6f }, .{ 0x000c77, 0x000c80 }, .{ 0x000c82, 0x000c8c },
        .{ 0x000c8e, 0x000c90 }, .{ 0x000c92, 0x000ca8 }, .{ 0x000caa, 0x000cb3 },
        .{ 0x000cb5, 0x000cb9 }, .{ 0x000cbd, 0x000cbe }, .{ 0x000cc3, 0x000cc4 },
        .{ 0x000cdc, 0x000cde }, .{ 0x000ce0, 0x000ce1 }, .{ 0x000ce6, 0x000cef },
        .{ 0x000cf1, 0x000cf3 }, .{ 0x000d02, 0x000d0c }, .{ 0x000d0e, 0x000d10 },
        .{ 0x000d12, 0x000d3a }, .{ 0x000d3f, 0x000d40 }, .{ 0x000d46, 0x000d48 },
        .{ 0x000d4a, 0x000d4c }, .{ 0x000d4e, 0x000d4f }, .{ 0x000d54, 0x000d56 },
        .{ 0x000d58, 0x000d61 }, .{ 0x000d66, 0x000d7f }, .{ 0x000d82, 0x000d83 },
        .{ 0x000d85, 0x000d96 }, .{ 0x000d9a, 0x000db1 }, .{ 0x000db3, 0x000dbb },
        .{ 0x000dc0, 0x000dc6 }, .{ 0x000dd0, 0x000dd1 }, .{ 0x000dd8, 0x000dde },
        .{ 0x000de6, 0x000def }, .{ 0x000df2, 0x000df4 }, .{ 0x000e01, 0x000e30 },
        .{ 0x000e32, 0x000e33 }, .{ 0x000e3f, 0x000e46 }, .{ 0x000e4f, 0x000e5b },
        .{ 0x000e81, 0x000e82 }, .{ 0x000e86, 0x000e8a }, .{ 0x000e8c, 0x000ea3 },
        .{ 0x000ea7, 0x000eb0 }, .{ 0x000eb2, 0x000eb3 }, .{ 0x000ec0, 0x000ec4 },
        .{ 0x000ed0, 0x000ed9 }, .{ 0x000edc, 0x000edf }, .{ 0x000f00, 0x000f17 },
        .{ 0x000f1a, 0x000f34 }, .{ 0x000f3a, 0x000f47 }, .{ 0x000f49, 0x000f6c },
        .{ 0x000f88, 0x000f8c }, .{ 0x000fbe, 0x000fc5 }, .{ 0x000fc7, 0x000fcc },
        .{ 0x000fce, 0x000fda }, .{ 0x001000, 0x00102c }, .{ 0x00103b, 0x00103c },
        .{ 0x00103f, 0x001057 }, .{ 0x00105a, 0x00105d }, .{ 0x001061, 0x001070 },
        .{ 0x001075, 0x001081 }, .{ 0x001083, 0x001084 }, .{ 0x001087, 0x00108c },
        .{ 0x00108e, 0x00109c }, .{ 0x00109e, 0x0010c5 }, .{ 0x0010d0, 0x001248 },
        .{ 0x00124a, 0x00124d }, .{ 0x001250, 0x001256 }, .{ 0x00125a, 0x00125d },
        .{ 0x001260, 0x001288 }, .{ 0x00128a, 0x00128d }, .{ 0x001290, 0x0012b0 },
        .{ 0x0012b2, 0x0012b5 }, .{ 0x0012b8, 0x0012be }, .{ 0x0012c2, 0x0012c5 },
        .{ 0x0012c8, 0x0012d6 }, .{ 0x0012d8, 0x001310 }, .{ 0x001312, 0x001315 },
        .{ 0x001318, 0x00135a }, .{ 0x001360, 0x00137c }, .{ 0x001380, 0x001399 },
        .{ 0x0013a0, 0x0013f5 }, .{ 0x0013f8, 0x0013fd }, .{ 0x001400, 0x00169c },
        .{ 0x0016a0, 0x0016f8 }, .{ 0x001700, 0x001711 }, .{ 0x00171f, 0x001731 },
        .{ 0x001735, 0x001736 }, .{ 0x001740, 0x001751 }, .{ 0x001760, 0x00176c },
        .{ 0x00176e, 0x001770 }, .{ 0x001780, 0x0017b3 }, .{ 0x0017be, 0x0017c5 },
        .{ 0x0017c7, 0x0017c8 }, .{ 0x0017d4, 0x0017dc }, .{ 0x0017e0, 0x0017e9 },
        .{ 0x0017f0, 0x0017f9 }, .{ 0x001800, 0x00180a }, .{ 0x001810, 0x001819 },
        .{ 0x001820, 0x001878 }, .{ 0x001880, 0x001884 }, .{ 0x001887, 0x0018a8 },
        .{ 0x0018b0, 0x0018f5 }, .{ 0x001900, 0x00191e }, .{ 0x001923, 0x001926 },
        .{ 0x001929, 0x00192b }, .{ 0x001930, 0x001931 }, .{ 0x001933, 0x001938 },
        .{ 0x001944, 0x00196d }, .{ 0x001970, 0x001974 }, .{ 0x001980, 0x0019ab },
        .{ 0x0019b0, 0x0019c9 }, .{ 0x0019d0, 0x0019da }, .{ 0x0019de, 0x001a16 },
        .{ 0x001a19, 0x001a1a }, .{ 0x001a1e, 0x001a55 }, .{ 0x001a63, 0x001a64 },
        .{ 0x001a6d, 0x001a72 }, .{ 0x001a80, 0x001a89 }, .{ 0x001a90, 0x001a99 },
        .{ 0x001aa0, 0x001aad }, .{ 0x001b04, 0x001b33 }, .{ 0x001b3e, 0x001b41 },
        .{ 0x001b45, 0x001b4c }, .{ 0x001b4e, 0x001b6a }, .{ 0x001b74, 0x001b7f },
        .{ 0x001b82, 0x001ba1 }, .{ 0x001ba6, 0x001ba7 }, .{ 0x001bae, 0x001be5 },
        .{ 0x001bea, 0x001bec }, .{ 0x001bfc, 0x001c2b }, .{ 0x001c34, 0x001c35 },
        .{ 0x001c3b, 0x001c49 }, .{ 0x001c4d, 0x001c8a }, .{ 0x001c90, 0x001cba },
        .{ 0x001cbd, 0x001cc7 }, .{ 0x001ce9, 0x001cec }, .{ 0x001cee, 0x001cf3 },
        .{ 0x001cf5, 0x001cf7 }, .{ 0x001d00, 0x001dbf }, .{ 0x001e00, 0x001f15 },
        .{ 0x001f18, 0x001f1d }, .{ 0x001f20, 0x001f45 }, .{ 0x001f48, 0x001f4d },
        .{ 0x001f50, 0x001f57 }, .{ 0x001f5f, 0x001f7d }, .{ 0x001f80, 0x001fb4 },
        .{ 0x001fb6, 0x001fc4 }, .{ 0x001fc6, 0x001fd3 }, .{ 0x001fd6, 0x001fdb },
        .{ 0x001fdd, 0x001fef }, .{ 0x001ff2, 0x001ff4 }, .{ 0x001ff6, 0x001ffe },
        .{ 0x002000, 0x00200a }, .{ 0x002010, 0x002027 }, .{ 0x00202f, 0x00205f },
        .{ 0x002070, 0x002071 }, .{ 0x002074, 0x00208e }, .{ 0x002090, 0x00209c },
        .{ 0x0020a0, 0x0020c1 }, .{ 0x002100, 0x00218b }, .{ 0x002190, 0x002429 },
        .{ 0x002440, 0x00244a }, .{ 0x002460, 0x002b73 }, .{ 0x002b76, 0x002cee },
        .{ 0x002cf2, 0x002cf3 }, .{ 0x002cf9, 0x002d25 }, .{ 0x002d30, 0x002d67 },
        .{ 0x002d6f, 0x002d70 }, .{ 0x002d80, 0x002d96 }, .{ 0x002da0, 0x002da6 },
        .{ 0x002da8, 0x002dae }, .{ 0x002db0, 0x002db6 }, .{ 0x002db8, 0x002dbe },
        .{ 0x002dc0, 0x002dc6 }, .{ 0x002dc8, 0x002dce }, .{ 0x002dd0, 0x002dd6 },
        .{ 0x002dd8, 0x002dde }, .{ 0x002e00, 0x002e5d }, .{ 0x002e80, 0x002e99 },
        .{ 0x002e9b, 0x002ef3 }, .{ 0x002f00, 0x002fd5 }, .{ 0x002ff0, 0x003029 },
        .{ 0x003030, 0x00303f }, .{ 0x003041, 0x003096 }, .{ 0x00309b, 0x0030ff },
        .{ 0x003105, 0x00312f }, .{ 0x003131, 0x00318e }, .{ 0x003190, 0x0031e5 },
        .{ 0x0031ef, 0x00321e }, .{ 0x003220, 0x00a48c }, .{ 0x00a490, 0x00a4c6 },
        .{ 0x00a4d0, 0x00a62b }, .{ 0x00a640, 0x00a66e }, .{ 0x00a67e, 0x00a69d },
        .{ 0x00a6a0, 0x00a6ef }, .{ 0x00a6f2, 0x00a6f7 }, .{ 0x00a700, 0x00a7dc },
        .{ 0x00a7f1, 0x00a801 }, .{ 0x00a803, 0x00a805 }, .{ 0x00a807, 0x00a80a },
        .{ 0x00a80c, 0x00a824 }, .{ 0x00a827, 0x00a82b }, .{ 0x00a830, 0x00a839 },
        .{ 0x00a840, 0x00a877 }, .{ 0x00a880, 0x00a8c3 }, .{ 0x00a8ce, 0x00a8d9 },
        .{ 0x00a8f2, 0x00a8fe }, .{ 0x00a900, 0x00a925 }, .{ 0x00a92e, 0x00a946 },
        .{ 0x00a95f, 0x00a97c }, .{ 0x00a983, 0x00a9b2 }, .{ 0x00a9b4, 0x00a9b5 },
        .{ 0x00a9ba, 0x00a9bb }, .{ 0x00a9be, 0x00a9bf }, .{ 0x00a9c1, 0x00a9cd },
        .{ 0x00a9cf, 0x00a9d9 }, .{ 0x00a9de, 0x00a9e4 }, .{ 0x00a9e6, 0x00a9fe },
        .{ 0x00aa00, 0x00aa28 }, .{ 0x00aa2f, 0x00aa30 }, .{ 0x00aa33, 0x00aa34 },
        .{ 0x00aa40, 0x00aa42 }, .{ 0x00aa44, 0x00aa4b }, .{ 0x00aa50, 0x00aa59 },
        .{ 0x00aa5c, 0x00aa7b }, .{ 0x00aa7d, 0x00aaaf }, .{ 0x00aab5, 0x00aab6 },
        .{ 0x00aab9, 0x00aabd }, .{ 0x00aadb, 0x00aaeb }, .{ 0x00aaee, 0x00aaf5 },
        .{ 0x00ab01, 0x00ab06 }, .{ 0x00ab09, 0x00ab0e }, .{ 0x00ab11, 0x00ab16 },
        .{ 0x00ab20, 0x00ab26 }, .{ 0x00ab28, 0x00ab2e }, .{ 0x00ab30, 0x00ab6b },
        .{ 0x00ab70, 0x00abe4 }, .{ 0x00abe6, 0x00abe7 }, .{ 0x00abe9, 0x00abec },
        .{ 0x00abf0, 0x00abf9 }, .{ 0x00ac00, 0x00d7a3 }, .{ 0x00d7b0, 0x00d7c6 },
        .{ 0x00d7cb, 0x00d7fb }, .{ 0x00f900, 0x00fa6d }, .{ 0x00fa70, 0x00fad9 },
        .{ 0x00fb00, 0x00fb06 }, .{ 0x00fb13, 0x00fb17 }, .{ 0x00fb1f, 0x00fb36 },
        .{ 0x00fb38, 0x00fb3c }, .{ 0x00fb40, 0x00fb41 }, .{ 0x00fb43, 0x00fb44 },
        .{ 0x00fb46, 0x00fdcf }, .{ 0x00fdf0, 0x00fdff }, .{ 0x00fe10, 0x00fe19 },
        .{ 0x00fe30, 0x00fe52 }, .{ 0x00fe54, 0x00fe66 }, .{ 0x00fe68, 0x00fe6b },
        .{ 0x00fe70, 0x00fe74 }, .{ 0x00fe76, 0x00fefc }, .{ 0x00ff01, 0x00ff9d },
        .{ 0x00ffa0, 0x00ffbe }, .{ 0x00ffc2, 0x00ffc7 }, .{ 0x00ffca, 0x00ffcf },
        .{ 0x00ffd2, 0x00ffd7 }, .{ 0x00ffda, 0x00ffdc }, .{ 0x00ffe0, 0x00ffe6 },
        .{ 0x00ffe8, 0x00ffee }, .{ 0x00fffc, 0x00fffd }, .{ 0x010000, 0x01000b },
        .{ 0x01000d, 0x010026 }, .{ 0x010028, 0x01003a }, .{ 0x01003c, 0x01003d },
        .{ 0x01003f, 0x01004d }, .{ 0x010050, 0x01005d }, .{ 0x010080, 0x0100fa },
        .{ 0x010100, 0x010102 }, .{ 0x010107, 0x010133 }, .{ 0x010137, 0x01018e },
        .{ 0x010190, 0x01019c }, .{ 0x0101d0, 0x0101fc }, .{ 0x010280, 0x01029c },
        .{ 0x0102a0, 0x0102d0 }, .{ 0x0102e1, 0x0102fb }, .{ 0x010300, 0x010323 },
        .{ 0x01032d, 0x01034a }, .{ 0x010350, 0x010375 }, .{ 0x010380, 0x01039d },
        .{ 0x01039f, 0x0103c3 }, .{ 0x0103c8, 0x0103d5 }, .{ 0x010400, 0x01049d },
        .{ 0x0104a0, 0x0104a9 }, .{ 0x0104b0, 0x0104d3 }, .{ 0x0104d8, 0x0104fb },
        .{ 0x010500, 0x010527 }, .{ 0x010530, 0x010563 }, .{ 0x01056f, 0x01057a },
        .{ 0x01057c, 0x01058a }, .{ 0x01058c, 0x010592 }, .{ 0x010594, 0x010595 },
        .{ 0x010597, 0x0105a1 }, .{ 0x0105a3, 0x0105b1 }, .{ 0x0105b3, 0x0105b9 },
        .{ 0x0105bb, 0x0105bc }, .{ 0x0105c0, 0x0105f3 }, .{ 0x010600, 0x010736 },
        .{ 0x010740, 0x010755 }, .{ 0x010760, 0x010767 }, .{ 0x010780, 0x010785 },
        .{ 0x010787, 0x0107b0 }, .{ 0x0107b2, 0x0107ba }, .{ 0x010800, 0x010805 },
        .{ 0x01080a, 0x010835 }, .{ 0x010837, 0x010838 }, .{ 0x01083f, 0x010855 },
        .{ 0x010857, 0x01089e }, .{ 0x0108a7, 0x0108af }, .{ 0x0108e0, 0x0108f2 },
        .{ 0x0108f4, 0x0108f5 }, .{ 0x0108fb, 0x01091b }, .{ 0x01091f, 0x010939 },
        .{ 0x01093f, 0x010959 }, .{ 0x010980, 0x0109b7 }, .{ 0x0109bc, 0x0109cf },
        .{ 0x0109d2, 0x010a00 }, .{ 0x010a10, 0x010a13 }, .{ 0x010a15, 0x010a17 },
        .{ 0x010a19, 0x010a35 }, .{ 0x010a40, 0x010a48 }, .{ 0x010a50, 0x010a58 },
        .{ 0x010a60, 0x010a9f }, .{ 0x010ac0, 0x010ae4 }, .{ 0x010aeb, 0x010af6 },
        .{ 0x010b00, 0x010b35 }, .{ 0x010b39, 0x010b55 }, .{ 0x010b58, 0x010b72 },
        .{ 0x010b78, 0x010b91 }, .{ 0x010b99, 0x010b9c }, .{ 0x010ba9, 0x010baf },
        .{ 0x010c00, 0x010c48 }, .{ 0x010c80, 0x010cb2 }, .{ 0x010cc0, 0x010cf2 },
        .{ 0x010cfa, 0x010d23 }, .{ 0x010d30, 0x010d39 }, .{ 0x010d40, 0x010d65 },
        .{ 0x010d6e, 0x010d85 }, .{ 0x010d8e, 0x010d8f }, .{ 0x010e60, 0x010e7e },
        .{ 0x010e80, 0x010ea9 }, .{ 0x010eb0, 0x010eb1 }, .{ 0x010ec2, 0x010ec7 },
        .{ 0x010ed0, 0x010ed8 }, .{ 0x010f00, 0x010f27 }, .{ 0x010f30, 0x010f45 },
        .{ 0x010f51, 0x010f59 }, .{ 0x010f70, 0x010f81 }, .{ 0x010f86, 0x010f89 },
        .{ 0x010fb0, 0x010fcb }, .{ 0x010fe0, 0x010ff6 }, .{ 0x011002, 0x011037 },
        .{ 0x011047, 0x01104d }, .{ 0x011052, 0x01106f }, .{ 0x011071, 0x011072 },
        .{ 0x011082, 0x0110b2 }, .{ 0x0110b7, 0x0110b8 }, .{ 0x0110bb, 0x0110bc },
        .{ 0x0110be, 0x0110c1 }, .{ 0x0110d0, 0x0110e8 }, .{ 0x0110f0, 0x0110f9 },
        .{ 0x011103, 0x011126 }, .{ 0x011136, 0x011147 }, .{ 0x011150, 0x011172 },
        .{ 0x011174, 0x011176 }, .{ 0x011182, 0x0111b5 }, .{ 0x0111c1, 0x0111c8 },
        .{ 0x0111cd, 0x0111ce }, .{ 0x0111d0, 0x0111df }, .{ 0x0111e1, 0x0111f4 },
        .{ 0x011200, 0x011211 }, .{ 0x011213, 0x01122e }, .{ 0x011232, 0x011233 },
        .{ 0x011238, 0x01123d }, .{ 0x01123f, 0x011240 }, .{ 0x011280, 0x011286 },
        .{ 0x01128a, 0x01128d }, .{ 0x01128f, 0x01129d }, .{ 0x01129f, 0x0112a9 },
        .{ 0x0112b0, 0x0112de }, .{ 0x0112e0, 0x0112e2 }, .{ 0x0112f0, 0x0112f9 },
        .{ 0x011302, 0x011303 }, .{ 0x011305, 0x01130c }, .{ 0x01130f, 0x011310 },
        .{ 0x011313, 0x011328 }, .{ 0x01132a, 0x011330 }, .{ 0x011332, 0x011333 },
        .{ 0x011335, 0x011339 }, .{ 0x011341, 0x011344 }, .{ 0x011347, 0x011348 },
        .{ 0x01134b, 0x01134c }, .{ 0x01135d, 0x011363 }, .{ 0x011380, 0x011389 },
        .{ 0x011390, 0x0113b5 }, .{ 0x0113b9, 0x0113ba }, .{ 0x0113cc, 0x0113cd },
        .{ 0x0113d3, 0x0113d5 }, .{ 0x0113d7, 0x0113d8 }, .{ 0x011400, 0x011437 },
        .{ 0x011440, 0x011441 }, .{ 0x011447, 0x01145b }, .{ 0x01145f, 0x011461 },
        .{ 0x011480, 0x0114af }, .{ 0x0114b1, 0x0114b2 }, .{ 0x0114bb, 0x0114bc },
        .{ 0x0114c4, 0x0114c7 }, .{ 0x0114d0, 0x0114d9 }, .{ 0x011580, 0x0115ae },
        .{ 0x0115b0, 0x0115b1 }, .{ 0x0115b8, 0x0115bb }, .{ 0x0115c1, 0x0115db },
        .{ 0x011600, 0x011632 }, .{ 0x01163b, 0x01163c }, .{ 0x011641, 0x011644 },
        .{ 0x011650, 0x011659 }, .{ 0x011660, 0x01166c }, .{ 0x011680, 0x0116aa },
        .{ 0x0116ae, 0x0116af }, .{ 0x0116b8, 0x0116b9 }, .{ 0x0116c0, 0x0116c9 },
        .{ 0x0116d0, 0x0116e3 }, .{ 0x011700, 0x01171a }, .{ 0x011720, 0x011721 },
        .{ 0x011730, 0x011746 }, .{ 0x011800, 0x01182e }, .{ 0x0118a0, 0x0118f2 },
        .{ 0x0118ff, 0x011906 }, .{ 0x01190c, 0x011913 }, .{ 0x011915, 0x011916 },
        .{ 0x011918, 0x01192f }, .{ 0x011931, 0x011935 }, .{ 0x011937, 0x011938 },
        .{ 0x01193f, 0x011942 }, .{ 0x011944, 0x011946 }, .{ 0x011950, 0x011959 },
        .{ 0x0119a0, 0x0119a7 }, .{ 0x0119aa, 0x0119d3 }, .{ 0x0119dc, 0x0119df },
        .{ 0x0119e1, 0x0119e4 }, .{ 0x011a0b, 0x011a32 }, .{ 0x011a39, 0x011a3a },
        .{ 0x011a3f, 0x011a46 }, .{ 0x011a57, 0x011a58 }, .{ 0x011a5c, 0x011a89 },
        .{ 0x011a9a, 0x011aa2 }, .{ 0x011ab0, 0x011af8 }, .{ 0x011b00, 0x011b09 },
        .{ 0x011bc0, 0x011be1 }, .{ 0x011bf0, 0x011bf9 }, .{ 0x011c00, 0x011c08 },
        .{ 0x011c0a, 0x011c2f }, .{ 0x011c40, 0x011c45 }, .{ 0x011c50, 0x011c6c },
        .{ 0x011c70, 0x011c8f }, .{ 0x011d00, 0x011d06 }, .{ 0x011d08, 0x011d09 },
        .{ 0x011d0b, 0x011d30 }, .{ 0x011d50, 0x011d59 }, .{ 0x011d60, 0x011d65 },
        .{ 0x011d67, 0x011d68 }, .{ 0x011d6a, 0x011d8e }, .{ 0x011d93, 0x011d94 },
        .{ 0x011da0, 0x011da9 }, .{ 0x011db0, 0x011ddb }, .{ 0x011de0, 0x011de9 },
        .{ 0x011ee0, 0x011ef2 }, .{ 0x011ef5, 0x011ef8 }, .{ 0x011f02, 0x011f10 },
        .{ 0x011f12, 0x011f35 }, .{ 0x011f3e, 0x011f3f }, .{ 0x011f43, 0x011f59 },
        .{ 0x011fc0, 0x011ff1 }, .{ 0x011fff, 0x012399 }, .{ 0x012400, 0x01246e },
        .{ 0x012470, 0x012474 }, .{ 0x012480, 0x012543 }, .{ 0x012f90, 0x012ff2 },
        .{ 0x013000, 0x01342f }, .{ 0x013441, 0x013446 }, .{ 0x013460, 0x0143fa },
        .{ 0x014400, 0x014646 }, .{ 0x016100, 0x01611d }, .{ 0x01612a, 0x01612c },
        .{ 0x016130, 0x016139 }, .{ 0x016800, 0x016a38 }, .{ 0x016a40, 0x016a5e },
        .{ 0x016a60, 0x016a69 }, .{ 0x016a6e, 0x016abe }, .{ 0x016ac0, 0x016ac9 },
        .{ 0x016ad0, 0x016aed }, .{ 0x016b00, 0x016b2f }, .{ 0x016b37, 0x016b45 },
        .{ 0x016b50, 0x016b59 }, .{ 0x016b5b, 0x016b61 }, .{ 0x016b63, 0x016b77 },
        .{ 0x016b7d, 0x016b8f }, .{ 0x016d40, 0x016d79 }, .{ 0x016e40, 0x016e9a },
        .{ 0x016ea0, 0x016eb8 }, .{ 0x016ebb, 0x016ed3 }, .{ 0x016f00, 0x016f4a },
        .{ 0x016f50, 0x016f87 }, .{ 0x016f93, 0x016f9f }, .{ 0x016fe0, 0x016fe3 },
        .{ 0x016ff2, 0x016ff6 }, .{ 0x017000, 0x018cd5 }, .{ 0x018cff, 0x018d1e },
        .{ 0x018d80, 0x018df2 }, .{ 0x01aff0, 0x01aff3 }, .{ 0x01aff5, 0x01affb },
        .{ 0x01affd, 0x01affe }, .{ 0x01b000, 0x01b122 }, .{ 0x01b150, 0x01b152 },
        .{ 0x01b164, 0x01b167 }, .{ 0x01b170, 0x01b2fb }, .{ 0x01bc00, 0x01bc6a },
        .{ 0x01bc70, 0x01bc7c }, .{ 0x01bc80, 0x01bc88 }, .{ 0x01bc90, 0x01bc99 },
        .{ 0x01cc00, 0x01ccfc }, .{ 0x01cd00, 0x01ceb3 }, .{ 0x01ceba, 0x01ced0 },
        .{ 0x01cee0, 0x01cef0 }, .{ 0x01cf50, 0x01cfc3 }, .{ 0x01d000, 0x01d0f5 },
        .{ 0x01d100, 0x01d126 }, .{ 0x01d129, 0x01d164 }, .{ 0x01d16a, 0x01d16c },
        .{ 0x01d183, 0x01d184 }, .{ 0x01d18c, 0x01d1a9 }, .{ 0x01d1ae, 0x01d1ea },
        .{ 0x01d200, 0x01d241 }, .{ 0x01d2c0, 0x01d2d3 }, .{ 0x01d2e0, 0x01d2f3 },
        .{ 0x01d300, 0x01d356 }, .{ 0x01d360, 0x01d378 }, .{ 0x01d400, 0x01d454 },
        .{ 0x01d456, 0x01d49c }, .{ 0x01d49e, 0x01d49f }, .{ 0x01d4a5, 0x01d4a6 },
        .{ 0x01d4a9, 0x01d4ac }, .{ 0x01d4ae, 0x01d4b9 }, .{ 0x01d4bd, 0x01d4c3 },
        .{ 0x01d4c5, 0x01d505 }, .{ 0x01d507, 0x01d50a }, .{ 0x01d50d, 0x01d514 },
        .{ 0x01d516, 0x01d51c }, .{ 0x01d51e, 0x01d539 }, .{ 0x01d53b, 0x01d53e },
        .{ 0x01d540, 0x01d544 }, .{ 0x01d54a, 0x01d550 }, .{ 0x01d552, 0x01d6a5 },
        .{ 0x01d6a8, 0x01d7cb }, .{ 0x01d7ce, 0x01d9ff }, .{ 0x01da37, 0x01da3a },
        .{ 0x01da6d, 0x01da74 }, .{ 0x01da76, 0x01da83 }, .{ 0x01da85, 0x01da8b },
        .{ 0x01df00, 0x01df1e }, .{ 0x01df25, 0x01df2a }, .{ 0x01e030, 0x01e06d },
        .{ 0x01e100, 0x01e12c }, .{ 0x01e137, 0x01e13d }, .{ 0x01e140, 0x01e149 },
        .{ 0x01e14e, 0x01e14f }, .{ 0x01e290, 0x01e2ad }, .{ 0x01e2c0, 0x01e2eb },
        .{ 0x01e2f0, 0x01e2f9 }, .{ 0x01e4d0, 0x01e4eb }, .{ 0x01e4f0, 0x01e4f9 },
        .{ 0x01e5d0, 0x01e5ed }, .{ 0x01e5f0, 0x01e5fa }, .{ 0x01e6c0, 0x01e6de },
        .{ 0x01e6e0, 0x01e6e2 }, .{ 0x01e6e4, 0x01e6e5 }, .{ 0x01e6e7, 0x01e6ed },
        .{ 0x01e6f0, 0x01e6f4 }, .{ 0x01e6fe, 0x01e6ff }, .{ 0x01e7e0, 0x01e7e6 },
        .{ 0x01e7e8, 0x01e7eb }, .{ 0x01e7ed, 0x01e7ee }, .{ 0x01e7f0, 0x01e7fe },
        .{ 0x01e800, 0x01e8c4 }, .{ 0x01e8c7, 0x01e8cf }, .{ 0x01e900, 0x01e943 },
        .{ 0x01e950, 0x01e959 }, .{ 0x01e95e, 0x01e95f }, .{ 0x01ec71, 0x01ecb4 },
        .{ 0x01ed01, 0x01ed3d }, .{ 0x01ee00, 0x01ee03 }, .{ 0x01ee05, 0x01ee1f },
        .{ 0x01ee21, 0x01ee22 }, .{ 0x01ee29, 0x01ee32 }, .{ 0x01ee34, 0x01ee37 },
        .{ 0x01ee4d, 0x01ee4f }, .{ 0x01ee51, 0x01ee52 }, .{ 0x01ee61, 0x01ee62 },
        .{ 0x01ee67, 0x01ee6a }, .{ 0x01ee6c, 0x01ee72 }, .{ 0x01ee74, 0x01ee77 },
        .{ 0x01ee79, 0x01ee7c }, .{ 0x01ee80, 0x01ee89 }, .{ 0x01ee8b, 0x01ee9b },
        .{ 0x01eea1, 0x01eea3 }, .{ 0x01eea5, 0x01eea9 }, .{ 0x01eeab, 0x01eebb },
        .{ 0x01eef0, 0x01eef1 }, .{ 0x01f000, 0x01f02b }, .{ 0x01f030, 0x01f093 },
        .{ 0x01f0a0, 0x01f0ae }, .{ 0x01f0b1, 0x01f0bf }, .{ 0x01f0c1, 0x01f0cf },
        .{ 0x01f0d1, 0x01f0f5 }, .{ 0x01f100, 0x01f1ad }, .{ 0x01f1e6, 0x01f202 },
        .{ 0x01f210, 0x01f23b }, .{ 0x01f240, 0x01f248 }, .{ 0x01f250, 0x01f251 },
        .{ 0x01f260, 0x01f265 }, .{ 0x01f300, 0x01f6d8 }, .{ 0x01f6dc, 0x01f6ec },
        .{ 0x01f6f0, 0x01f6fc }, .{ 0x01f700, 0x01f7d9 }, .{ 0x01f7e0, 0x01f7eb },
        .{ 0x01f800, 0x01f80b }, .{ 0x01f810, 0x01f847 }, .{ 0x01f850, 0x01f859 },
        .{ 0x01f860, 0x01f887 }, .{ 0x01f890, 0x01f8ad }, .{ 0x01f8b0, 0x01f8bb },
        .{ 0x01f8c0, 0x01f8c1 }, .{ 0x01f8d0, 0x01f8d8 }, .{ 0x01f900, 0x01fa57 },
        .{ 0x01fa60, 0x01fa6d }, .{ 0x01fa70, 0x01fa7c }, .{ 0x01fa80, 0x01fa8a },
        .{ 0x01fa8e, 0x01fac6 }, .{ 0x01facd, 0x01fadc }, .{ 0x01fadf, 0x01faea },
        .{ 0x01faef, 0x01faf8 }, .{ 0x01fb00, 0x01fb92 }, .{ 0x01fb94, 0x01fbfa },
        .{ 0x020000, 0x02a6df }, .{ 0x02a700, 0x02b81d }, .{ 0x02b820, 0x02cead },
        .{ 0x02ceb0, 0x02ebe0 }, .{ 0x02ebf0, 0x02ee5d }, .{ 0x02f800, 0x02fa1d },
        .{ 0x030000, 0x03134a }, .{ 0x031350, 0x033479 },
    };
    return code_point <= 0x10ffff and
        (codePointInSortedUnicodeRanges(code_point, &ranges) or
            codePointInSortedUnicodeSingles(code_point, &singles));
}
pub fn isUnicodeHexDigitCodePoint(code_point: u21) bool {
    return (code_point <= 0x7f and std.ascii.isHex(@intCast(code_point))) or
        (code_point >= 0xff10 and code_point <= 0xff19) or
        (code_point >= 0xff21 and code_point <= 0xff26) or
        (code_point >= 0xff41 and code_point <= 0xff46);
}

pub fn isUnicodeCasedCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000aa, 0x0000b5, 0x0000ba, 0x000345, 0x00037f, 0x000386, 0x00038c, 0x0010c7,
        0x0010cd, 0x001f59, 0x001f5b, 0x001f5d, 0x001fbe, 0x002071, 0x00207f, 0x002102,
        0x002107, 0x002115, 0x002124, 0x002126, 0x002128, 0x002139, 0x00214e, 0x002d27,
        0x002d2d, 0x010780, 0x01d4a2, 0x01d4bb, 0x01d546,
    };
    const ranges = [_][2]u21{
        .{ 0x000041, 0x00005a },
        .{ 0x000061, 0x00007a },
        .{ 0x0000c0, 0x0000d6 },
        .{ 0x0000d8, 0x0000f6 },
        .{ 0x0000f8, 0x0001ba },
        .{ 0x0001bc, 0x0001bf },
        .{ 0x0001c4, 0x000293 },
        .{ 0x000296, 0x0002b8 },
        .{ 0x0002c0, 0x0002c1 },
        .{ 0x0002e0, 0x0002e4 },
        .{ 0x000370, 0x000373 },
        .{ 0x000376, 0x000377 },
        .{ 0x00037a, 0x00037d },
        .{ 0x000388, 0x00038a },
        .{ 0x00038e, 0x0003a1 },
        .{ 0x0003a3, 0x0003f5 },
        .{ 0x0003f7, 0x000481 },
        .{ 0x00048a, 0x00052f },
        .{ 0x000531, 0x000556 },
        .{ 0x000560, 0x000588 },
        .{ 0x0010a0, 0x0010c5 },
        .{ 0x0010d0, 0x0010fa },
        .{ 0x0010fc, 0x0010ff },
        .{ 0x0013a0, 0x0013f5 },
        .{ 0x0013f8, 0x0013fd },
        .{ 0x001c80, 0x001c8a },
        .{ 0x001c90, 0x001cba },
        .{ 0x001cbd, 0x001cbf },
        .{ 0x001d00, 0x001dbf },
        .{ 0x001e00, 0x001f15 },
        .{ 0x001f18, 0x001f1d },
        .{ 0x001f20, 0x001f45 },
        .{ 0x001f48, 0x001f4d },
        .{ 0x001f50, 0x001f57 },
        .{ 0x001f5f, 0x001f7d },
        .{ 0x001f80, 0x001fb4 },
        .{ 0x001fb6, 0x001fbc },
        .{ 0x001fc2, 0x001fc4 },
        .{ 0x001fc6, 0x001fcc },
        .{ 0x001fd0, 0x001fd3 },
        .{ 0x001fd6, 0x001fdb },
        .{ 0x001fe0, 0x001fec },
        .{ 0x001ff2, 0x001ff4 },
        .{ 0x001ff6, 0x001ffc },
        .{ 0x002090, 0x00209c },
        .{ 0x00210a, 0x002113 },
        .{ 0x002119, 0x00211d },
        .{ 0x00212a, 0x00212d },
        .{ 0x00212f, 0x002134 },
        .{ 0x00213c, 0x00213f },
        .{ 0x002145, 0x002149 },
        .{ 0x002160, 0x00217f },
        .{ 0x002183, 0x002184 },
        .{ 0x0024b6, 0x0024e9 },
        .{ 0x002c00, 0x002ce4 },
        .{ 0x002ceb, 0x002cee },
        .{ 0x002cf2, 0x002cf3 },
        .{ 0x002d00, 0x002d25 },
        .{ 0x00a640, 0x00a66d },
        .{ 0x00a680, 0x00a69d },
        .{ 0x00a722, 0x00a787 },
        .{ 0x00a78b, 0x00a78e },
        .{ 0x00a790, 0x00a7dc },
        .{ 0x00a7f1, 0x00a7f6 },
        .{ 0x00a7f8, 0x00a7fa },
        .{ 0x00ab30, 0x00ab5a },
        .{ 0x00ab5c, 0x00ab69 },
        .{ 0x00ab70, 0x00abbf },
        .{ 0x00fb00, 0x00fb06 },
        .{ 0x00fb13, 0x00fb17 },
        .{ 0x00ff21, 0x00ff3a },
        .{ 0x00ff41, 0x00ff5a },
        .{ 0x010400, 0x01044f },
        .{ 0x0104b0, 0x0104d3 },
        .{ 0x0104d8, 0x0104fb },
        .{ 0x010570, 0x01057a },
        .{ 0x01057c, 0x01058a },
        .{ 0x01058c, 0x010592 },
        .{ 0x010594, 0x010595 },
        .{ 0x010597, 0x0105a1 },
        .{ 0x0105a3, 0x0105b1 },
        .{ 0x0105b3, 0x0105b9 },
        .{ 0x0105bb, 0x0105bc },
        .{ 0x010783, 0x010785 },
        .{ 0x010787, 0x0107b0 },
        .{ 0x0107b2, 0x0107ba },
        .{ 0x010c80, 0x010cb2 },
        .{ 0x010cc0, 0x010cf2 },
        .{ 0x010d50, 0x010d65 },
        .{ 0x010d70, 0x010d85 },
        .{ 0x0118a0, 0x0118df },
        .{ 0x016e40, 0x016e7f },
        .{ 0x016ea0, 0x016eb8 },
        .{ 0x016ebb, 0x016ed3 },
        .{ 0x01d400, 0x01d454 },
        .{ 0x01d456, 0x01d49c },
        .{ 0x01d49e, 0x01d49f },
        .{ 0x01d4a5, 0x01d4a6 },
        .{ 0x01d4a9, 0x01d4ac },
        .{ 0x01d4ae, 0x01d4b9 },
        .{ 0x01d4bd, 0x01d4c3 },
        .{ 0x01d4c5, 0x01d505 },
        .{ 0x01d507, 0x01d50a },
        .{ 0x01d50d, 0x01d514 },
        .{ 0x01d516, 0x01d51c },
        .{ 0x01d51e, 0x01d539 },
        .{ 0x01d53b, 0x01d53e },
        .{ 0x01d540, 0x01d544 },
        .{ 0x01d54a, 0x01d550 },
        .{ 0x01d552, 0x01d6a5 },
        .{ 0x01d6a8, 0x01d6c0 },
        .{ 0x01d6c2, 0x01d6da },
        .{ 0x01d6dc, 0x01d6fa },
        .{ 0x01d6fc, 0x01d714 },
        .{ 0x01d716, 0x01d734 },
        .{ 0x01d736, 0x01d74e },
        .{ 0x01d750, 0x01d76e },
        .{ 0x01d770, 0x01d788 },
        .{ 0x01d78a, 0x01d7a8 },
        .{ 0x01d7aa, 0x01d7c2 },
        .{ 0x01d7c4, 0x01d7cb },
        .{ 0x01df00, 0x01df09 },
        .{ 0x01df0b, 0x01df1e },
        .{ 0x01df25, 0x01df2a },
        .{ 0x01e030, 0x01e06d },
        .{ 0x01e900, 0x01e943 },
        .{ 0x01f130, 0x01f149 },
        .{ 0x01f150, 0x01f169 },
        .{ 0x01f170, 0x01f189 },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeDashCodePoint(code_point: u21) bool {
    return code_point == 0x00002d or
        code_point == 0x00058a or
        code_point == 0x0005be or
        code_point == 0x001400 or
        code_point == 0x001806 or
        code_point == 0x002053 or
        code_point == 0x00207b or
        code_point == 0x00208b or
        code_point == 0x002212 or
        code_point == 0x002e17 or
        code_point == 0x002e1a or
        code_point == 0x002e40 or
        code_point == 0x002e5d or
        code_point == 0x00301c or
        code_point == 0x003030 or
        code_point == 0x0030a0 or
        code_point == 0x00fe58 or
        code_point == 0x00fe63 or
        code_point == 0x00ff0d or
        code_point == 0x010d6e or
        code_point == 0x010ead or
        (code_point >= 0x002010 and code_point <= 0x002015) or
        (code_point >= 0x002e3a and code_point <= 0x002e3b) or
        (code_point >= 0x00fe31 and code_point <= 0x00fe32);
}

pub fn isUnicodeBidiMirroredCodePoint(code_point: u21) bool {
    return code_point == 0x00003c or
        code_point == 0x00003e or
        code_point == 0x00005b or
        code_point == 0x00005d or
        code_point == 0x00007b or
        code_point == 0x00007d or
        code_point == 0x0000ab or
        code_point == 0x0000bb or
        code_point == 0x002140 or
        code_point == 0x002211 or
        code_point == 0x002224 or
        code_point == 0x002226 or
        code_point == 0x002239 or
        code_point == 0x002262 or
        code_point == 0x002298 or
        code_point == 0x0027c0 or
        code_point == 0x0029b8 or
        code_point == 0x0029c9 or
        code_point == 0x0029e1 or
        code_point == 0x002a24 or
        code_point == 0x002a26 or
        code_point == 0x002a29 or
        code_point == 0x002adc or
        code_point == 0x002ade or
        code_point == 0x002af3 or
        code_point == 0x002afd or
        code_point == 0x002bfe or
        code_point == 0x00ff1c or
        code_point == 0x00ff1e or
        code_point == 0x00ff3b or
        code_point == 0x00ff3d or
        code_point == 0x00ff5b or
        code_point == 0x00ff5d or
        code_point == 0x01d6db or
        code_point == 0x01d715 or
        code_point == 0x01d74f or
        code_point == 0x01d789 or
        code_point == 0x01d7c3 or
        (code_point >= 0x000028 and code_point <= 0x000029) or
        (code_point >= 0x000f3a and code_point <= 0x000f3d) or
        (code_point >= 0x00169b and code_point <= 0x00169c) or
        (code_point >= 0x002039 and code_point <= 0x00203a) or
        (code_point >= 0x002045 and code_point <= 0x002046) or
        (code_point >= 0x00207d and code_point <= 0x00207e) or
        (code_point >= 0x00208d and code_point <= 0x00208e) or
        (code_point >= 0x002201 and code_point <= 0x002204) or
        (code_point >= 0x002208 and code_point <= 0x00220d) or
        (code_point >= 0x002215 and code_point <= 0x002216) or
        (code_point >= 0x00221a and code_point <= 0x00221d) or
        (code_point >= 0x00221f and code_point <= 0x002222) or
        (code_point >= 0x00222b and code_point <= 0x002233) or
        (code_point >= 0x00223b and code_point <= 0x00224c) or
        (code_point >= 0x002252 and code_point <= 0x002255) or
        (code_point >= 0x00225f and code_point <= 0x002260) or
        (code_point >= 0x002264 and code_point <= 0x00226b) or
        (code_point >= 0x00226d and code_point <= 0x00228c) or
        (code_point >= 0x00228f and code_point <= 0x002292) or
        (code_point >= 0x0022a2 and code_point <= 0x0022a3) or
        (code_point >= 0x0022a6 and code_point <= 0x0022b8) or
        (code_point >= 0x0022be and code_point <= 0x0022bf) or
        (code_point >= 0x0022c9 and code_point <= 0x0022cd) or
        (code_point >= 0x0022d0 and code_point <= 0x0022d1) or
        (code_point >= 0x0022d6 and code_point <= 0x0022ed) or
        (code_point >= 0x0022f0 and code_point <= 0x0022ff) or
        (code_point >= 0x002308 and code_point <= 0x00230b) or
        (code_point >= 0x002320 and code_point <= 0x002321) or
        (code_point >= 0x002329 and code_point <= 0x00232a) or
        (code_point >= 0x002768 and code_point <= 0x002775) or
        (code_point >= 0x0027c3 and code_point <= 0x0027c6) or
        (code_point >= 0x0027c8 and code_point <= 0x0027c9) or
        (code_point >= 0x0027cb and code_point <= 0x0027cd) or
        (code_point >= 0x0027d3 and code_point <= 0x0027d6) or
        (code_point >= 0x0027dc and code_point <= 0x0027de) or
        (code_point >= 0x0027e2 and code_point <= 0x0027ef) or
        (code_point >= 0x002983 and code_point <= 0x002998) or
        (code_point >= 0x00299b and code_point <= 0x0029a0) or
        (code_point >= 0x0029a2 and code_point <= 0x0029af) or
        (code_point >= 0x0029c0 and code_point <= 0x0029c5) or
        (code_point >= 0x0029ce and code_point <= 0x0029d2) or
        (code_point >= 0x0029d4 and code_point <= 0x0029d5) or
        (code_point >= 0x0029d8 and code_point <= 0x0029dc) or
        (code_point >= 0x0029e3 and code_point <= 0x0029e5) or
        (code_point >= 0x0029e8 and code_point <= 0x0029e9) or
        (code_point >= 0x0029f4 and code_point <= 0x0029f9) or
        (code_point >= 0x0029fc and code_point <= 0x0029fd) or
        (code_point >= 0x002a0a and code_point <= 0x002a1c) or
        (code_point >= 0x002a1e and code_point <= 0x002a21) or
        (code_point >= 0x002a2b and code_point <= 0x002a2e) or
        (code_point >= 0x002a34 and code_point <= 0x002a35) or
        (code_point >= 0x002a3c and code_point <= 0x002a3e) or
        (code_point >= 0x002a57 and code_point <= 0x002a58) or
        (code_point >= 0x002a64 and code_point <= 0x002a65) or
        (code_point >= 0x002a6a and code_point <= 0x002a6d) or
        (code_point >= 0x002a6f and code_point <= 0x002a70) or
        (code_point >= 0x002a73 and code_point <= 0x002a74) or
        (code_point >= 0x002a79 and code_point <= 0x002aa3) or
        (code_point >= 0x002aa6 and code_point <= 0x002aad) or
        (code_point >= 0x002aaf and code_point <= 0x002ad6) or
        (code_point >= 0x002ae2 and code_point <= 0x002ae6) or
        (code_point >= 0x002aec and code_point <= 0x002aee) or
        (code_point >= 0x002af7 and code_point <= 0x002afb) or
        (code_point >= 0x002e02 and code_point <= 0x002e05) or
        (code_point >= 0x002e09 and code_point <= 0x002e0a) or
        (code_point >= 0x002e0c and code_point <= 0x002e0d) or
        (code_point >= 0x002e1c and code_point <= 0x002e1d) or
        (code_point >= 0x002e20 and code_point <= 0x002e29) or
        (code_point >= 0x002e55 and code_point <= 0x002e5c) or
        (code_point >= 0x003008 and code_point <= 0x003011) or
        (code_point >= 0x003014 and code_point <= 0x00301b) or
        (code_point >= 0x00fe59 and code_point <= 0x00fe5e) or
        (code_point >= 0x00fe64 and code_point <= 0x00fe65) or
        (code_point >= 0x00ff08 and code_point <= 0x00ff09) or
        (code_point >= 0x00ff5f and code_point <= 0x00ff60) or
        (code_point >= 0x00ff62 and code_point <= 0x00ff63);
}

pub fn isUnicodeBidiControlCodePoint(code_point: u21) bool {
    return code_point == 0x00061c or
        (code_point >= 0x00200e and code_point <= 0x00200f) or
        (code_point >= 0x00202a and code_point <= 0x00202e) or
        (code_point >= 0x002066 and code_point <= 0x002069);
}

pub fn isUnicodeDeprecatedCodePoint(code_point: u21) bool {
    return code_point == 0x000149 or
        code_point == 0x000673 or
        code_point == 0x000f77 or
        code_point == 0x000f79 or
        code_point == 0x0e0001 or
        (code_point >= 0x0017a3 and code_point <= 0x0017a4) or
        (code_point >= 0x00206a and code_point <= 0x00206f) or
        (code_point >= 0x002329 and code_point <= 0x00232a);
}

pub fn isUnicodeDiacriticCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x00005e, 0x000060, 0x0000a8, 0x0000af, 0x0000b4, 0x00037a, 0x000559, 0x0005bf,
        0x0005c7, 0x00093c, 0x00094d, 0x000971, 0x0009bc, 0x0009cd, 0x000a3c, 0x000a4d,
        0x000abc, 0x000acd, 0x000b3c, 0x000b4d, 0x000b55, 0x000bcd, 0x000c3c, 0x000c4d,
        0x000cbc, 0x000ccd, 0x000d4d, 0x000dca, 0x000e3a, 0x000e4e, 0x000eba, 0x000f35,
        0x000f37, 0x000f39, 0x000fc6, 0x001037, 0x00108f, 0x001734, 0x0017dd, 0x001a60,
        0x001a7f, 0x001b34, 0x001b44, 0x001be6, 0x001ced, 0x001cf4, 0x001fbd, 0x002e2f,
        0x0030fc, 0x00a66f, 0x00a67f, 0x00a7f1, 0x00a806, 0x00a82c, 0x00a8c4, 0x00a953,
        0x00a9b3, 0x00a9c0, 0x00a9e5, 0x00aaf6, 0x00fb1e, 0x00ff3e, 0x00ff40, 0x00ff70,
        0x00ffe3, 0x0102e0, 0x010a3f, 0x010d4e, 0x010efa, 0x011046, 0x011070, 0x011173,
        0x0111c0, 0x01134d, 0x011442, 0x011446, 0x01163f, 0x01172b, 0x011943, 0x0119e0,
        0x011a34, 0x011a47, 0x011a99, 0x011c3f, 0x011d42, 0x011d97, 0x011dd9, 0x011f5a,
        0x01612f, 0x01e2ae,
    };
    const ranges = [_][2]u21{
        .{ 0x0000b7, 0x0000b8 },
        .{ 0x0002b0, 0x00034e },
        .{ 0x000350, 0x000357 },
        .{ 0x00035d, 0x000362 },
        .{ 0x000374, 0x000375 },
        .{ 0x000384, 0x000385 },
        .{ 0x000483, 0x000487 },
        .{ 0x000591, 0x0005bd },
        .{ 0x0005c1, 0x0005c2 },
        .{ 0x0005c4, 0x0005c5 },
        .{ 0x00064b, 0x000652 },
        .{ 0x000657, 0x000658 },
        .{ 0x0006df, 0x0006e0 },
        .{ 0x0006e5, 0x0006e6 },
        .{ 0x0006ea, 0x0006ec },
        .{ 0x000730, 0x00074a },
        .{ 0x0007a6, 0x0007b0 },
        .{ 0x0007eb, 0x0007f5 },
        .{ 0x000818, 0x000819 },
        .{ 0x000898, 0x00089f },
        .{ 0x0008c9, 0x0008d2 },
        .{ 0x0008e3, 0x0008fe },
        .{ 0x000951, 0x000954 },
        .{ 0x000afd, 0x000aff },
        .{ 0x000d3b, 0x000d3c },
        .{ 0x000e47, 0x000e4c },
        .{ 0x000ec8, 0x000ecc },
        .{ 0x000f18, 0x000f19 },
        .{ 0x000f3e, 0x000f3f },
        .{ 0x000f82, 0x000f84 },
        .{ 0x000f86, 0x000f87 },
        .{ 0x001039, 0x00103a },
        .{ 0x001063, 0x001064 },
        .{ 0x001069, 0x00106d },
        .{ 0x001087, 0x00108d },
        .{ 0x00109a, 0x00109b },
        .{ 0x00135d, 0x00135f },
        .{ 0x001714, 0x001715 },
        .{ 0x0017c9, 0x0017d3 },
        .{ 0x001939, 0x00193b },
        .{ 0x001a75, 0x001a7c },
        .{ 0x001ab0, 0x001abe },
        .{ 0x001ac1, 0x001acb },
        .{ 0x001acf, 0x001add },
        .{ 0x001ae0, 0x001aeb },
        .{ 0x001b6b, 0x001b73 },
        .{ 0x001baa, 0x001bab },
        .{ 0x001bf2, 0x001bf3 },
        .{ 0x001c36, 0x001c37 },
        .{ 0x001c78, 0x001c7d },
        .{ 0x001cd0, 0x001ce8 },
        .{ 0x001cf7, 0x001cf9 },
        .{ 0x001d2c, 0x001d6a },
        .{ 0x001d9b, 0x001dbe },
        .{ 0x001dc4, 0x001dcf },
        .{ 0x001df5, 0x001dff },
        .{ 0x001fbf, 0x001fc1 },
        .{ 0x001fcd, 0x001fcf },
        .{ 0x001fdd, 0x001fdf },
        .{ 0x001fed, 0x001fef },
        .{ 0x001ffd, 0x001ffe },
        .{ 0x002cef, 0x002cf1 },
        .{ 0x00302a, 0x00302f },
        .{ 0x003099, 0x00309c },
        .{ 0x00a67c, 0x00a67d },
        .{ 0x00a69c, 0x00a69d },
        .{ 0x00a6f0, 0x00a6f1 },
        .{ 0x00a700, 0x00a721 },
        .{ 0x00a788, 0x00a78a },
        .{ 0x00a7f8, 0x00a7f9 },
        .{ 0x00a8e0, 0x00a8f1 },
        .{ 0x00a92b, 0x00a92e },
        .{ 0x00aa7b, 0x00aa7d },
        .{ 0x00aabf, 0x00aac2 },
        .{ 0x00ab5b, 0x00ab5f },
        .{ 0x00ab69, 0x00ab6b },
        .{ 0x00abec, 0x00abed },
        .{ 0x00fe20, 0x00fe2f },
        .{ 0x00ff9e, 0x00ff9f },
        .{ 0x010780, 0x010785 },
        .{ 0x010787, 0x0107b0 },
        .{ 0x0107b2, 0x0107ba },
        .{ 0x010a38, 0x010a3a },
        .{ 0x010ae5, 0x010ae6 },
        .{ 0x010d22, 0x010d27 },
        .{ 0x010d69, 0x010d6d },
        .{ 0x010efd, 0x010eff },
        .{ 0x010f46, 0x010f50 },
        .{ 0x010f82, 0x010f85 },
        .{ 0x0110b9, 0x0110ba },
        .{ 0x011133, 0x011134 },
        .{ 0x0111ca, 0x0111cc },
        .{ 0x011235, 0x011236 },
        .{ 0x0112e9, 0x0112ea },
        .{ 0x01133b, 0x01133c },
        .{ 0x011366, 0x01136c },
        .{ 0x011370, 0x011374 },
        .{ 0x0113ce, 0x0113d0 },
        .{ 0x0113d2, 0x0113d3 },
        .{ 0x0113e1, 0x0113e2 },
        .{ 0x0114c2, 0x0114c3 },
        .{ 0x0115bf, 0x0115c0 },
        .{ 0x0116b6, 0x0116b7 },
        .{ 0x011839, 0x01183a },
        .{ 0x01193d, 0x01193e },
        .{ 0x011d44, 0x011d45 },
        .{ 0x011f41, 0x011f42 },
        .{ 0x013447, 0x013455 },
        .{ 0x016af0, 0x016af4 },
        .{ 0x016b30, 0x016b36 },
        .{ 0x016d6b, 0x016d6c },
        .{ 0x016f8f, 0x016f9f },
        .{ 0x016ff0, 0x016ff1 },
        .{ 0x01aff0, 0x01aff3 },
        .{ 0x01aff5, 0x01affb },
        .{ 0x01affd, 0x01affe },
        .{ 0x01cf00, 0x01cf2d },
        .{ 0x01cf30, 0x01cf46 },
        .{ 0x01d167, 0x01d169 },
        .{ 0x01d16d, 0x01d172 },
        .{ 0x01d17b, 0x01d182 },
        .{ 0x01d185, 0x01d18b },
        .{ 0x01d1aa, 0x01d1ad },
        .{ 0x01e030, 0x01e06d },
        .{ 0x01e130, 0x01e136 },
        .{ 0x01e2ec, 0x01e2ef },
        .{ 0x01e5ee, 0x01e5ef },
        .{ 0x01e8d0, 0x01e8d6 },
        .{ 0x01e944, 0x01e946 },
        .{ 0x01e948, 0x01e94a },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeIdsBinaryOperatorCodePoint(code_point: u21) bool {
    return code_point == 0x0031ef or
        (code_point >= 0x002ff0 and code_point <= 0x002ff1) or
        (code_point >= 0x002ff4 and code_point <= 0x002ffd);
}

pub fn isUnicodeIdsTrinaryOperatorCodePoint(code_point: u21) bool {
    return code_point >= 0x002ff2 and code_point <= 0x002ff3;
}

pub fn isUnicodeRadicalCodePoint(code_point: u21) bool {
    return (code_point >= 0x002e80 and code_point <= 0x002e99) or
        (code_point >= 0x002e9b and code_point <= 0x002ef3) or
        (code_point >= 0x002f00 and code_point <= 0x002fd5);
}

pub fn isUnicodeVariationSelectorCodePoint(code_point: u21) bool {
    return code_point == 0x00180f or
        (code_point >= 0x00180b and code_point <= 0x00180d) or
        (code_point >= 0x00fe00 and code_point <= 0x00fe0f) or
        (code_point >= 0x0e0100 and code_point <= 0x0e01ef);
}

pub fn isUnicodeQuotationMarkCodePoint(code_point: u21) bool {
    return code_point == 0x000022 or
        code_point == 0x000027 or
        code_point == 0x0000ab or
        code_point == 0x0000bb or
        code_point == 0x002e42 or
        code_point == 0x00ff02 or
        code_point == 0x00ff07 or
        (code_point >= 0x002018 and code_point <= 0x00201f) or
        (code_point >= 0x002039 and code_point <= 0x00203a) or
        (code_point >= 0x00300c and code_point <= 0x00300f) or
        (code_point >= 0x00301d and code_point <= 0x00301f) or
        (code_point >= 0x00fe41 and code_point <= 0x00fe44) or
        (code_point >= 0x00ff62 and code_point <= 0x00ff63);
}

pub fn isUnicodePatternWhiteSpaceCodePoint(code_point: u21) bool {
    return code_point == 0x000020 or
        code_point == 0x000085 or
        (code_point >= 0x000009 and code_point <= 0x00000d) or
        (code_point >= 0x00200e and code_point <= 0x00200f) or
        (code_point >= 0x002028 and code_point <= 0x002029);
}

pub fn isUnicodeWhiteSpaceCodePoint(code_point: u21) bool {
    return code_point == 0x000020 or
        code_point == 0x000085 or
        code_point == 0x0000a0 or
        code_point == 0x001680 or
        code_point == 0x00202f or
        code_point == 0x00205f or
        code_point == 0x003000 or
        (code_point >= 0x000009 and code_point <= 0x00000d) or
        (code_point >= 0x002000 and code_point <= 0x00200a) or
        (code_point >= 0x002028 and code_point <= 0x002029);
}

pub fn isUnicodeLogicalOrderExceptionCodePoint(code_point: u21) bool {
    return code_point == 0x0019ba or
        code_point == 0x00aab9 or
        (code_point >= 0x000e40 and code_point <= 0x000e44) or
        (code_point >= 0x000ec0 and code_point <= 0x000ec4) or
        (code_point >= 0x0019b5 and code_point <= 0x0019b7) or
        (code_point >= 0x00aab5 and code_point <= 0x00aab6) or
        (code_point >= 0x00aabb and code_point <= 0x00aabc);
}

pub fn isUnicodeNoncharacterCodePoint(code_point: u21) bool {
    return (code_point >= 0x00fdd0 and code_point <= 0x00fdef) or
        ((code_point & 0xfffe) == 0xfffe and code_point >= 0x00fffe and code_point <= 0x10ffff);
}

pub fn isUnicodePatternSyntaxCodePoint(code_point: u21) bool {
    return code_point == 0x000060 or
        code_point == 0x0000a9 or
        code_point == 0x0000ae or
        code_point == 0x0000b6 or
        code_point == 0x0000bb or
        code_point == 0x0000bf or
        code_point == 0x0000d7 or
        code_point == 0x0000f7 or
        code_point == 0x003030 or
        (code_point >= 0x000021 and code_point <= 0x00002f) or
        (code_point >= 0x00003a and code_point <= 0x000040) or
        (code_point >= 0x00005b and code_point <= 0x00005e) or
        (code_point >= 0x00007b and code_point <= 0x00007e) or
        (code_point >= 0x0000a1 and code_point <= 0x0000a7) or
        (code_point >= 0x0000ab and code_point <= 0x0000ac) or
        (code_point >= 0x0000b0 and code_point <= 0x0000b1) or
        (code_point >= 0x002010 and code_point <= 0x002027) or
        (code_point >= 0x002030 and code_point <= 0x00203e) or
        (code_point >= 0x002041 and code_point <= 0x002053) or
        (code_point >= 0x002055 and code_point <= 0x00205e) or
        (code_point >= 0x002190 and code_point <= 0x00245f) or
        (code_point >= 0x002500 and code_point <= 0x002775) or
        (code_point >= 0x002794 and code_point <= 0x002bff) or
        (code_point >= 0x002e00 and code_point <= 0x002e7f) or
        (code_point >= 0x003001 and code_point <= 0x003003) or
        (code_point >= 0x003008 and code_point <= 0x003020) or
        (code_point >= 0x00fd3e and code_point <= 0x00fd3f) or
        (code_point >= 0x00fe45 and code_point <= 0x00fe46);
}

pub fn isUnicodeDefaultIgnorableCodePoint(code_point: u21) bool {
    return code_point == 0x0000ad or
        code_point == 0x00034f or
        code_point == 0x00061c or
        code_point == 0x003164 or
        code_point == 0x00feff or
        code_point == 0x00ffa0 or
        (code_point >= 0x00115f and code_point <= 0x001160) or
        (code_point >= 0x0017b4 and code_point <= 0x0017b5) or
        (code_point >= 0x00180b and code_point <= 0x00180f) or
        (code_point >= 0x00200b and code_point <= 0x00200f) or
        (code_point >= 0x00202a and code_point <= 0x00202e) or
        (code_point >= 0x002060 and code_point <= 0x00206f) or
        (code_point >= 0x00fe00 and code_point <= 0x00fe0f) or
        (code_point >= 0x00fff0 and code_point <= 0x00fff8) or
        (code_point >= 0x01bca0 and code_point <= 0x01bca3) or
        (code_point >= 0x01d173 and code_point <= 0x01d17a) or
        (code_point >= 0x0e0000 and code_point <= 0x0e0fff);
}

pub fn isUnicodeExtendedPictographicCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000a9, 0x0000ae, 0x00203c, 0x002049, 0x002122, 0x002139, 0x002328, 0x0023cf,
        0x0024c2, 0x0025b6, 0x0025c0, 0x00260e, 0x002611, 0x002618, 0x00261d, 0x002620,
        0x002626, 0x00262a, 0x002640, 0x002642, 0x002663, 0x002668, 0x00267b, 0x002699,
        0x0026a7, 0x0026c8, 0x0026d1, 0x0026fd, 0x002702, 0x002705, 0x00270f, 0x002712,
        0x002714, 0x002716, 0x00271d, 0x002721, 0x002728, 0x002744, 0x002747, 0x00274c,
        0x00274e, 0x002757, 0x0027a1, 0x0027b0, 0x0027bf, 0x002b50, 0x002b55, 0x003030,
        0x00303d, 0x003297, 0x003299, 0x01f004, 0x01f0c0, 0x01f18e, 0x01f21a, 0x01f22f,
        0x01f587, 0x01f590, 0x01f5a8, 0x01f5bc, 0x01f5e1, 0x01f5e3, 0x01f5e8, 0x01f5ef,
        0x01f5f3, 0x01f6e9,
    };
    const ranges = [_][2]u21{
        .{ 0x002194, 0x002199 },
        .{ 0x0021a9, 0x0021aa },
        .{ 0x00231a, 0x00231b },
        .{ 0x0023e9, 0x0023f3 },
        .{ 0x0023f8, 0x0023fa },
        .{ 0x0025aa, 0x0025ab },
        .{ 0x0025fb, 0x0025fe },
        .{ 0x002600, 0x002604 },
        .{ 0x002614, 0x002615 },
        .{ 0x002622, 0x002623 },
        .{ 0x00262e, 0x00262f },
        .{ 0x002638, 0x00263a },
        .{ 0x002648, 0x002653 },
        .{ 0x00265f, 0x002660 },
        .{ 0x002665, 0x002666 },
        .{ 0x00267e, 0x00267f },
        .{ 0x002692, 0x002697 },
        .{ 0x00269b, 0x00269c },
        .{ 0x0026a0, 0x0026a1 },
        .{ 0x0026aa, 0x0026ab },
        .{ 0x0026b0, 0x0026b1 },
        .{ 0x0026bd, 0x0026be },
        .{ 0x0026c4, 0x0026c5 },
        .{ 0x0026ce, 0x0026cf },
        .{ 0x0026d3, 0x0026d4 },
        .{ 0x0026e9, 0x0026ea },
        .{ 0x0026f0, 0x0026f5 },
        .{ 0x0026f7, 0x0026fa },
        .{ 0x002708, 0x00270d },
        .{ 0x002733, 0x002734 },
        .{ 0x002753, 0x002755 },
        .{ 0x002763, 0x002764 },
        .{ 0x002795, 0x002797 },
        .{ 0x002934, 0x002935 },
        .{ 0x002b05, 0x002b07 },
        .{ 0x002b1b, 0x002b1c },
        .{ 0x01f02c, 0x01f02f },
        .{ 0x01f094, 0x01f09f },
        .{ 0x01f0af, 0x01f0b0 },
        .{ 0x01f0cf, 0x01f0d0 },
        .{ 0x01f0f6, 0x01f0ff },
        .{ 0x01f170, 0x01f171 },
        .{ 0x01f17e, 0x01f17f },
        .{ 0x01f191, 0x01f19a },
        .{ 0x01f1ae, 0x01f1e5 },
        .{ 0x01f201, 0x01f20f },
        .{ 0x01f232, 0x01f23a },
        .{ 0x01f23c, 0x01f23f },
        .{ 0x01f249, 0x01f25f },
        .{ 0x01f266, 0x01f321 },
        .{ 0x01f324, 0x01f393 },
        .{ 0x01f396, 0x01f397 },
        .{ 0x01f399, 0x01f39b },
        .{ 0x01f39e, 0x01f3f0 },
        .{ 0x01f3f3, 0x01f3f5 },
        .{ 0x01f3f7, 0x01f3fa },
        .{ 0x01f400, 0x01f4fd },
        .{ 0x01f4ff, 0x01f53d },
        .{ 0x01f549, 0x01f54e },
        .{ 0x01f550, 0x01f567 },
        .{ 0x01f56f, 0x01f570 },
        .{ 0x01f573, 0x01f57a },
        .{ 0x01f58a, 0x01f58d },
        .{ 0x01f595, 0x01f596 },
        .{ 0x01f5a4, 0x01f5a5 },
        .{ 0x01f5b1, 0x01f5b2 },
        .{ 0x01f5c2, 0x01f5c4 },
        .{ 0x01f5d1, 0x01f5d3 },
        .{ 0x01f5dc, 0x01f5de },
        .{ 0x01f5fa, 0x01f64f },
        .{ 0x01f680, 0x01f6c5 },
        .{ 0x01f6cb, 0x01f6d2 },
        .{ 0x01f6d5, 0x01f6e5 },
        .{ 0x01f6eb, 0x01f6f0 },
        .{ 0x01f6f3, 0x01f6ff },
        .{ 0x01f7da, 0x01f7ff },
        .{ 0x01f80c, 0x01f80f },
        .{ 0x01f848, 0x01f84f },
        .{ 0x01f85a, 0x01f85f },
        .{ 0x01f888, 0x01f88f },
        .{ 0x01f8ae, 0x01f8af },
        .{ 0x01f8bc, 0x01f8bf },
        .{ 0x01f8c2, 0x01f8cf },
        .{ 0x01f8d9, 0x01f8ff },
        .{ 0x01f90c, 0x01f93a },
        .{ 0x01f93c, 0x01f945 },
        .{ 0x01f947, 0x01f9ff },
        .{ 0x01fa58, 0x01fa5f },
        .{ 0x01fa6e, 0x01faff },
        .{ 0x01fc00, 0x01fffd },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeAlphabeticCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000aa, 0x0000b5, 0x0000ba, 0x0002ec, 0x0002ee, 0x000345, 0x00037f, 0x000386,
        0x00038c, 0x000559, 0x0005bf, 0x0005c7, 0x0006ff, 0x0007fa, 0x000897, 0x0009b2,
        0x0009ce, 0x0009d7, 0x0009fc, 0x000a51, 0x000a5e, 0x000ad0, 0x000b71, 0x000b9c,
        0x000bd0, 0x000bd7, 0x000d4e, 0x000dbd, 0x000dd6, 0x000e4d, 0x000e84, 0x000ea5,
        0x000ec6, 0x000ecd, 0x000f00, 0x001038, 0x0010c7, 0x0010cd, 0x001258, 0x0012c0,
        0x0017d7, 0x0017dc, 0x001aa7, 0x001cfa, 0x001f59, 0x001f5b, 0x001f5d, 0x001fbe,
        0x002071, 0x00207f, 0x002102, 0x002107, 0x002115, 0x002124, 0x002126, 0x002128,
        0x00214e, 0x002d27, 0x002d2d, 0x002d6f, 0x002e2f, 0x00a8c5, 0x00a8fb, 0x00a9cf,
        0x00aac0, 0x00aac2, 0x00fb3e, 0x010808, 0x01083c, 0x010d69, 0x010f27, 0x0110c2,
        0x011176, 0x0111da, 0x0111dc, 0x011237, 0x011288, 0x011350, 0x011357, 0x01138b,
        0x01138e, 0x0113c2, 0x0113c5, 0x0113d1, 0x0113d3, 0x0114c7, 0x011640, 0x011644,
        0x0116b8, 0x011909, 0x0119e1, 0x011a9d, 0x011c40, 0x011d3a, 0x011d43, 0x011d98,
        0x011fb0, 0x016fe3, 0x01b132, 0x01b155, 0x01bc9e, 0x01d4a2, 0x01d4bb, 0x01d546,
        0x01e08f, 0x01e14e, 0x01e5f0, 0x01e947, 0x01e94b, 0x01ee24, 0x01ee27, 0x01ee39,
        0x01ee3b, 0x01ee42, 0x01ee47, 0x01ee49, 0x01ee4b, 0x01ee54, 0x01ee57, 0x01ee59,
        0x01ee5b, 0x01ee5d, 0x01ee5f, 0x01ee64, 0x01ee7e,
    };
    const ranges = [_][2]u21{
        .{ 0x000041, 0x00005a },
        .{ 0x000061, 0x00007a },
        .{ 0x0000c0, 0x0000d6 },
        .{ 0x0000d8, 0x0000f6 },
        .{ 0x0000f8, 0x0002c1 },
        .{ 0x0002c6, 0x0002d1 },
        .{ 0x0002e0, 0x0002e4 },
        .{ 0x000363, 0x000374 },
        .{ 0x000376, 0x000377 },
        .{ 0x00037a, 0x00037d },
        .{ 0x000388, 0x00038a },
        .{ 0x00038e, 0x0003a1 },
        .{ 0x0003a3, 0x0003f5 },
        .{ 0x0003f7, 0x000481 },
        .{ 0x00048a, 0x00052f },
        .{ 0x000531, 0x000556 },
        .{ 0x000560, 0x000588 },
        .{ 0x0005b0, 0x0005bd },
        .{ 0x0005c1, 0x0005c2 },
        .{ 0x0005c4, 0x0005c5 },
        .{ 0x0005d0, 0x0005ea },
        .{ 0x0005ef, 0x0005f2 },
        .{ 0x000610, 0x00061a },
        .{ 0x000620, 0x000657 },
        .{ 0x000659, 0x00065f },
        .{ 0x00066e, 0x0006d3 },
        .{ 0x0006d5, 0x0006dc },
        .{ 0x0006e1, 0x0006e8 },
        .{ 0x0006ed, 0x0006ef },
        .{ 0x0006fa, 0x0006fc },
        .{ 0x000710, 0x00073f },
        .{ 0x00074d, 0x0007b1 },
        .{ 0x0007ca, 0x0007ea },
        .{ 0x0007f4, 0x0007f5 },
        .{ 0x000800, 0x000817 },
        .{ 0x00081a, 0x00082c },
        .{ 0x000840, 0x000858 },
        .{ 0x000860, 0x00086a },
        .{ 0x000870, 0x000887 },
        .{ 0x000889, 0x00088f },
        .{ 0x0008a0, 0x0008c9 },
        .{ 0x0008d4, 0x0008df },
        .{ 0x0008e3, 0x0008e9 },
        .{ 0x0008f0, 0x00093b },
        .{ 0x00093d, 0x00094c },
        .{ 0x00094e, 0x000950 },
        .{ 0x000955, 0x000963 },
        .{ 0x000971, 0x000983 },
        .{ 0x000985, 0x00098c },
        .{ 0x00098f, 0x000990 },
        .{ 0x000993, 0x0009a8 },
        .{ 0x0009aa, 0x0009b0 },
        .{ 0x0009b6, 0x0009b9 },
        .{ 0x0009bd, 0x0009c4 },
        .{ 0x0009c7, 0x0009c8 },
        .{ 0x0009cb, 0x0009cc },
        .{ 0x0009dc, 0x0009dd },
        .{ 0x0009df, 0x0009e3 },
        .{ 0x0009f0, 0x0009f1 },
        .{ 0x000a01, 0x000a03 },
        .{ 0x000a05, 0x000a0a },
        .{ 0x000a0f, 0x000a10 },
        .{ 0x000a13, 0x000a28 },
        .{ 0x000a2a, 0x000a30 },
        .{ 0x000a32, 0x000a33 },
        .{ 0x000a35, 0x000a36 },
        .{ 0x000a38, 0x000a39 },
        .{ 0x000a3e, 0x000a42 },
        .{ 0x000a47, 0x000a48 },
        .{ 0x000a4b, 0x000a4c },
        .{ 0x000a59, 0x000a5c },
        .{ 0x000a70, 0x000a75 },
        .{ 0x000a81, 0x000a83 },
        .{ 0x000a85, 0x000a8d },
        .{ 0x000a8f, 0x000a91 },
        .{ 0x000a93, 0x000aa8 },
        .{ 0x000aaa, 0x000ab0 },
        .{ 0x000ab2, 0x000ab3 },
        .{ 0x000ab5, 0x000ab9 },
        .{ 0x000abd, 0x000ac5 },
        .{ 0x000ac7, 0x000ac9 },
        .{ 0x000acb, 0x000acc },
        .{ 0x000ae0, 0x000ae3 },
        .{ 0x000af9, 0x000afc },
        .{ 0x000b01, 0x000b03 },
        .{ 0x000b05, 0x000b0c },
        .{ 0x000b0f, 0x000b10 },
        .{ 0x000b13, 0x000b28 },
        .{ 0x000b2a, 0x000b30 },
        .{ 0x000b32, 0x000b33 },
        .{ 0x000b35, 0x000b39 },
        .{ 0x000b3d, 0x000b44 },
        .{ 0x000b47, 0x000b48 },
        .{ 0x000b4b, 0x000b4c },
        .{ 0x000b56, 0x000b57 },
        .{ 0x000b5c, 0x000b5d },
        .{ 0x000b5f, 0x000b63 },
        .{ 0x000b82, 0x000b83 },
        .{ 0x000b85, 0x000b8a },
        .{ 0x000b8e, 0x000b90 },
        .{ 0x000b92, 0x000b95 },
        .{ 0x000b99, 0x000b9a },
        .{ 0x000b9e, 0x000b9f },
        .{ 0x000ba3, 0x000ba4 },
        .{ 0x000ba8, 0x000baa },
        .{ 0x000bae, 0x000bb9 },
        .{ 0x000bbe, 0x000bc2 },
        .{ 0x000bc6, 0x000bc8 },
        .{ 0x000bca, 0x000bcc },
        .{ 0x000c00, 0x000c0c },
        .{ 0x000c0e, 0x000c10 },
        .{ 0x000c12, 0x000c28 },
        .{ 0x000c2a, 0x000c39 },
        .{ 0x000c3d, 0x000c44 },
        .{ 0x000c46, 0x000c48 },
        .{ 0x000c4a, 0x000c4c },
        .{ 0x000c55, 0x000c56 },
        .{ 0x000c58, 0x000c5a },
        .{ 0x000c5c, 0x000c5d },
        .{ 0x000c60, 0x000c63 },
        .{ 0x000c80, 0x000c83 },
        .{ 0x000c85, 0x000c8c },
        .{ 0x000c8e, 0x000c90 },
        .{ 0x000c92, 0x000ca8 },
        .{ 0x000caa, 0x000cb3 },
        .{ 0x000cb5, 0x000cb9 },
        .{ 0x000cbd, 0x000cc4 },
        .{ 0x000cc6, 0x000cc8 },
        .{ 0x000cca, 0x000ccc },
        .{ 0x000cd5, 0x000cd6 },
        .{ 0x000cdc, 0x000cde },
        .{ 0x000ce0, 0x000ce3 },
        .{ 0x000cf1, 0x000cf3 },
        .{ 0x000d00, 0x000d0c },
        .{ 0x000d0e, 0x000d10 },
        .{ 0x000d12, 0x000d3a },
        .{ 0x000d3d, 0x000d44 },
        .{ 0x000d46, 0x000d48 },
        .{ 0x000d4a, 0x000d4c },
        .{ 0x000d54, 0x000d57 },
        .{ 0x000d5f, 0x000d63 },
        .{ 0x000d7a, 0x000d7f },
        .{ 0x000d81, 0x000d83 },
        .{ 0x000d85, 0x000d96 },
        .{ 0x000d9a, 0x000db1 },
        .{ 0x000db3, 0x000dbb },
        .{ 0x000dc0, 0x000dc6 },
        .{ 0x000dcf, 0x000dd4 },
        .{ 0x000dd8, 0x000ddf },
        .{ 0x000df2, 0x000df3 },
        .{ 0x000e01, 0x000e3a },
        .{ 0x000e40, 0x000e46 },
        .{ 0x000e81, 0x000e82 },
        .{ 0x000e86, 0x000e8a },
        .{ 0x000e8c, 0x000ea3 },
        .{ 0x000ea7, 0x000eb9 },
        .{ 0x000ebb, 0x000ebd },
        .{ 0x000ec0, 0x000ec4 },
        .{ 0x000edc, 0x000edf },
        .{ 0x000f40, 0x000f47 },
        .{ 0x000f49, 0x000f6c },
        .{ 0x000f71, 0x000f83 },
        .{ 0x000f88, 0x000f97 },
        .{ 0x000f99, 0x000fbc },
        .{ 0x001000, 0x001036 },
        .{ 0x00103b, 0x00103f },
        .{ 0x001050, 0x00108f },
        .{ 0x00109a, 0x00109d },
        .{ 0x0010a0, 0x0010c5 },
        .{ 0x0010d0, 0x0010fa },
        .{ 0x0010fc, 0x001248 },
        .{ 0x00124a, 0x00124d },
        .{ 0x001250, 0x001256 },
        .{ 0x00125a, 0x00125d },
        .{ 0x001260, 0x001288 },
        .{ 0x00128a, 0x00128d },
        .{ 0x001290, 0x0012b0 },
        .{ 0x0012b2, 0x0012b5 },
        .{ 0x0012b8, 0x0012be },
        .{ 0x0012c2, 0x0012c5 },
        .{ 0x0012c8, 0x0012d6 },
        .{ 0x0012d8, 0x001310 },
        .{ 0x001312, 0x001315 },
        .{ 0x001318, 0x00135a },
        .{ 0x001380, 0x00138f },
        .{ 0x0013a0, 0x0013f5 },
        .{ 0x0013f8, 0x0013fd },
        .{ 0x001401, 0x00166c },
        .{ 0x00166f, 0x00167f },
        .{ 0x001681, 0x00169a },
        .{ 0x0016a0, 0x0016ea },
        .{ 0x0016ee, 0x0016f8 },
        .{ 0x001700, 0x001713 },
        .{ 0x00171f, 0x001733 },
        .{ 0x001740, 0x001753 },
        .{ 0x001760, 0x00176c },
        .{ 0x00176e, 0x001770 },
        .{ 0x001772, 0x001773 },
        .{ 0x001780, 0x0017b3 },
        .{ 0x0017b6, 0x0017c8 },
        .{ 0x001820, 0x001878 },
        .{ 0x001880, 0x0018aa },
        .{ 0x0018b0, 0x0018f5 },
        .{ 0x001900, 0x00191e },
        .{ 0x001920, 0x00192b },
        .{ 0x001930, 0x001938 },
        .{ 0x001950, 0x00196d },
        .{ 0x001970, 0x001974 },
        .{ 0x001980, 0x0019ab },
        .{ 0x0019b0, 0x0019c9 },
        .{ 0x001a00, 0x001a1b },
        .{ 0x001a20, 0x001a5e },
        .{ 0x001a61, 0x001a74 },
        .{ 0x001abf, 0x001ac0 },
        .{ 0x001acc, 0x001ace },
        .{ 0x001b00, 0x001b33 },
        .{ 0x001b35, 0x001b43 },
        .{ 0x001b45, 0x001b4c },
        .{ 0x001b80, 0x001ba9 },
        .{ 0x001bac, 0x001baf },
        .{ 0x001bba, 0x001be5 },
        .{ 0x001be7, 0x001bf1 },
        .{ 0x001c00, 0x001c36 },
        .{ 0x001c4d, 0x001c4f },
        .{ 0x001c5a, 0x001c7d },
        .{ 0x001c80, 0x001c8a },
        .{ 0x001c90, 0x001cba },
        .{ 0x001cbd, 0x001cbf },
        .{ 0x001ce9, 0x001cec },
        .{ 0x001cee, 0x001cf3 },
        .{ 0x001cf5, 0x001cf6 },
        .{ 0x001d00, 0x001dbf },
        .{ 0x001dd3, 0x001df4 },
        .{ 0x001e00, 0x001f15 },
        .{ 0x001f18, 0x001f1d },
        .{ 0x001f20, 0x001f45 },
        .{ 0x001f48, 0x001f4d },
        .{ 0x001f50, 0x001f57 },
        .{ 0x001f5f, 0x001f7d },
        .{ 0x001f80, 0x001fb4 },
        .{ 0x001fb6, 0x001fbc },
        .{ 0x001fc2, 0x001fc4 },
        .{ 0x001fc6, 0x001fcc },
        .{ 0x001fd0, 0x001fd3 },
        .{ 0x001fd6, 0x001fdb },
        .{ 0x001fe0, 0x001fec },
        .{ 0x001ff2, 0x001ff4 },
        .{ 0x001ff6, 0x001ffc },
        .{ 0x002090, 0x00209c },
        .{ 0x00210a, 0x002113 },
        .{ 0x002119, 0x00211d },
        .{ 0x00212a, 0x00212d },
        .{ 0x00212f, 0x002139 },
        .{ 0x00213c, 0x00213f },
        .{ 0x002145, 0x002149 },
        .{ 0x002160, 0x002188 },
        .{ 0x0024b6, 0x0024e9 },
        .{ 0x002c00, 0x002ce4 },
        .{ 0x002ceb, 0x002cee },
        .{ 0x002cf2, 0x002cf3 },
        .{ 0x002d00, 0x002d25 },
        .{ 0x002d30, 0x002d67 },
        .{ 0x002d80, 0x002d96 },
        .{ 0x002da0, 0x002da6 },
        .{ 0x002da8, 0x002dae },
        .{ 0x002db0, 0x002db6 },
        .{ 0x002db8, 0x002dbe },
        .{ 0x002dc0, 0x002dc6 },
        .{ 0x002dc8, 0x002dce },
        .{ 0x002dd0, 0x002dd6 },
        .{ 0x002dd8, 0x002dde },
        .{ 0x002de0, 0x002dff },
        .{ 0x003005, 0x003007 },
        .{ 0x003021, 0x003029 },
        .{ 0x003031, 0x003035 },
        .{ 0x003038, 0x00303c },
        .{ 0x003041, 0x003096 },
        .{ 0x00309d, 0x00309f },
        .{ 0x0030a1, 0x0030fa },
        .{ 0x0030fc, 0x0030ff },
        .{ 0x003105, 0x00312f },
        .{ 0x003131, 0x00318e },
        .{ 0x0031a0, 0x0031bf },
        .{ 0x0031f0, 0x0031ff },
        .{ 0x003400, 0x004dbf },
        .{ 0x004e00, 0x00a48c },
        .{ 0x00a4d0, 0x00a4fd },
        .{ 0x00a500, 0x00a60c },
        .{ 0x00a610, 0x00a61f },
        .{ 0x00a62a, 0x00a62b },
        .{ 0x00a640, 0x00a66e },
        .{ 0x00a674, 0x00a67b },
        .{ 0x00a67f, 0x00a6ef },
        .{ 0x00a717, 0x00a71f },
        .{ 0x00a722, 0x00a788 },
        .{ 0x00a78b, 0x00a7dc },
        .{ 0x00a7f1, 0x00a805 },
        .{ 0x00a807, 0x00a827 },
        .{ 0x00a840, 0x00a873 },
        .{ 0x00a880, 0x00a8c3 },
        .{ 0x00a8f2, 0x00a8f7 },
        .{ 0x00a8fd, 0x00a8ff },
        .{ 0x00a90a, 0x00a92a },
        .{ 0x00a930, 0x00a952 },
        .{ 0x00a960, 0x00a97c },
        .{ 0x00a980, 0x00a9b2 },
        .{ 0x00a9b4, 0x00a9bf },
        .{ 0x00a9e0, 0x00a9ef },
        .{ 0x00a9fa, 0x00a9fe },
        .{ 0x00aa00, 0x00aa36 },
        .{ 0x00aa40, 0x00aa4d },
        .{ 0x00aa60, 0x00aa76 },
        .{ 0x00aa7a, 0x00aabe },
        .{ 0x00aadb, 0x00aadd },
        .{ 0x00aae0, 0x00aaef },
        .{ 0x00aaf2, 0x00aaf5 },
        .{ 0x00ab01, 0x00ab06 },
        .{ 0x00ab09, 0x00ab0e },
        .{ 0x00ab11, 0x00ab16 },
        .{ 0x00ab20, 0x00ab26 },
        .{ 0x00ab28, 0x00ab2e },
        .{ 0x00ab30, 0x00ab5a },
        .{ 0x00ab5c, 0x00ab69 },
        .{ 0x00ab70, 0x00abea },
        .{ 0x00ac00, 0x00d7a3 },
        .{ 0x00d7b0, 0x00d7c6 },
        .{ 0x00d7cb, 0x00d7fb },
        .{ 0x00f900, 0x00fa6d },
        .{ 0x00fa70, 0x00fad9 },
        .{ 0x00fb00, 0x00fb06 },
        .{ 0x00fb13, 0x00fb17 },
        .{ 0x00fb1d, 0x00fb28 },
        .{ 0x00fb2a, 0x00fb36 },
        .{ 0x00fb38, 0x00fb3c },
        .{ 0x00fb40, 0x00fb41 },
        .{ 0x00fb43, 0x00fb44 },
        .{ 0x00fb46, 0x00fbb1 },
        .{ 0x00fbd3, 0x00fd3d },
        .{ 0x00fd50, 0x00fd8f },
        .{ 0x00fd92, 0x00fdc7 },
        .{ 0x00fdf0, 0x00fdfb },
        .{ 0x00fe70, 0x00fe74 },
        .{ 0x00fe76, 0x00fefc },
        .{ 0x00ff21, 0x00ff3a },
        .{ 0x00ff41, 0x00ff5a },
        .{ 0x00ff66, 0x00ffbe },
        .{ 0x00ffc2, 0x00ffc7 },
        .{ 0x00ffca, 0x00ffcf },
        .{ 0x00ffd2, 0x00ffd7 },
        .{ 0x00ffda, 0x00ffdc },
        .{ 0x010000, 0x01000b },
        .{ 0x01000d, 0x010026 },
        .{ 0x010028, 0x01003a },
        .{ 0x01003c, 0x01003d },
        .{ 0x01003f, 0x01004d },
        .{ 0x010050, 0x01005d },
        .{ 0x010080, 0x0100fa },
        .{ 0x010140, 0x010174 },
        .{ 0x010280, 0x01029c },
        .{ 0x0102a0, 0x0102d0 },
        .{ 0x010300, 0x01031f },
        .{ 0x01032d, 0x01034a },
        .{ 0x010350, 0x01037a },
        .{ 0x010380, 0x01039d },
        .{ 0x0103a0, 0x0103c3 },
        .{ 0x0103c8, 0x0103cf },
        .{ 0x0103d1, 0x0103d5 },
        .{ 0x010400, 0x01049d },
        .{ 0x0104b0, 0x0104d3 },
        .{ 0x0104d8, 0x0104fb },
        .{ 0x010500, 0x010527 },
        .{ 0x010530, 0x010563 },
        .{ 0x010570, 0x01057a },
        .{ 0x01057c, 0x01058a },
        .{ 0x01058c, 0x010592 },
        .{ 0x010594, 0x010595 },
        .{ 0x010597, 0x0105a1 },
        .{ 0x0105a3, 0x0105b1 },
        .{ 0x0105b3, 0x0105b9 },
        .{ 0x0105bb, 0x0105bc },
        .{ 0x0105c0, 0x0105f3 },
        .{ 0x010600, 0x010736 },
        .{ 0x010740, 0x010755 },
        .{ 0x010760, 0x010767 },
        .{ 0x010780, 0x010785 },
        .{ 0x010787, 0x0107b0 },
        .{ 0x0107b2, 0x0107ba },
        .{ 0x010800, 0x010805 },
        .{ 0x01080a, 0x010835 },
        .{ 0x010837, 0x010838 },
        .{ 0x01083f, 0x010855 },
        .{ 0x010860, 0x010876 },
        .{ 0x010880, 0x01089e },
        .{ 0x0108e0, 0x0108f2 },
        .{ 0x0108f4, 0x0108f5 },
        .{ 0x010900, 0x010915 },
        .{ 0x010920, 0x010939 },
        .{ 0x010940, 0x010959 },
        .{ 0x010980, 0x0109b7 },
        .{ 0x0109be, 0x0109bf },
        .{ 0x010a00, 0x010a03 },
        .{ 0x010a05, 0x010a06 },
        .{ 0x010a0c, 0x010a13 },
        .{ 0x010a15, 0x010a17 },
        .{ 0x010a19, 0x010a35 },
        .{ 0x010a60, 0x010a7c },
        .{ 0x010a80, 0x010a9c },
        .{ 0x010ac0, 0x010ac7 },
        .{ 0x010ac9, 0x010ae4 },
        .{ 0x010b00, 0x010b35 },
        .{ 0x010b40, 0x010b55 },
        .{ 0x010b60, 0x010b72 },
        .{ 0x010b80, 0x010b91 },
        .{ 0x010c00, 0x010c48 },
        .{ 0x010c80, 0x010cb2 },
        .{ 0x010cc0, 0x010cf2 },
        .{ 0x010d00, 0x010d27 },
        .{ 0x010d4a, 0x010d65 },
        .{ 0x010d6f, 0x010d85 },
        .{ 0x010e80, 0x010ea9 },
        .{ 0x010eab, 0x010eac },
        .{ 0x010eb0, 0x010eb1 },
        .{ 0x010ec2, 0x010ec7 },
        .{ 0x010efa, 0x010efc },
        .{ 0x010f00, 0x010f1c },
        .{ 0x010f30, 0x010f45 },
        .{ 0x010f70, 0x010f81 },
        .{ 0x010fb0, 0x010fc4 },
        .{ 0x010fe0, 0x010ff6 },
        .{ 0x011000, 0x011045 },
        .{ 0x011071, 0x011075 },
        .{ 0x011080, 0x0110b8 },
        .{ 0x0110d0, 0x0110e8 },
        .{ 0x011100, 0x011132 },
        .{ 0x011144, 0x011147 },
        .{ 0x011150, 0x011172 },
        .{ 0x011180, 0x0111bf },
        .{ 0x0111c1, 0x0111c4 },
        .{ 0x0111ce, 0x0111cf },
        .{ 0x011200, 0x011211 },
        .{ 0x011213, 0x011234 },
        .{ 0x01123e, 0x011241 },
        .{ 0x011280, 0x011286 },
        .{ 0x01128a, 0x01128d },
        .{ 0x01128f, 0x01129d },
        .{ 0x01129f, 0x0112a8 },
        .{ 0x0112b0, 0x0112e8 },
        .{ 0x011300, 0x011303 },
        .{ 0x011305, 0x01130c },
        .{ 0x01130f, 0x011310 },
        .{ 0x011313, 0x011328 },
        .{ 0x01132a, 0x011330 },
        .{ 0x011332, 0x011333 },
        .{ 0x011335, 0x011339 },
        .{ 0x01133d, 0x011344 },
        .{ 0x011347, 0x011348 },
        .{ 0x01134b, 0x01134c },
        .{ 0x01135d, 0x011363 },
        .{ 0x011380, 0x011389 },
        .{ 0x011390, 0x0113b5 },
        .{ 0x0113b7, 0x0113c0 },
        .{ 0x0113c7, 0x0113ca },
        .{ 0x0113cc, 0x0113cd },
        .{ 0x011400, 0x011441 },
        .{ 0x011443, 0x011445 },
        .{ 0x011447, 0x01144a },
        .{ 0x01145f, 0x011461 },
        .{ 0x011480, 0x0114c1 },
        .{ 0x0114c4, 0x0114c5 },
        .{ 0x011580, 0x0115b5 },
        .{ 0x0115b8, 0x0115be },
        .{ 0x0115d8, 0x0115dd },
        .{ 0x011600, 0x01163e },
        .{ 0x011680, 0x0116b5 },
        .{ 0x011700, 0x01171a },
        .{ 0x01171d, 0x01172a },
        .{ 0x011740, 0x011746 },
        .{ 0x011800, 0x011838 },
        .{ 0x0118a0, 0x0118df },
        .{ 0x0118ff, 0x011906 },
        .{ 0x01190c, 0x011913 },
        .{ 0x011915, 0x011916 },
        .{ 0x011918, 0x011935 },
        .{ 0x011937, 0x011938 },
        .{ 0x01193b, 0x01193c },
        .{ 0x01193f, 0x011942 },
        .{ 0x0119a0, 0x0119a7 },
        .{ 0x0119aa, 0x0119d7 },
        .{ 0x0119da, 0x0119df },
        .{ 0x0119e3, 0x0119e4 },
        .{ 0x011a00, 0x011a32 },
        .{ 0x011a35, 0x011a3e },
        .{ 0x011a50, 0x011a97 },
        .{ 0x011ab0, 0x011af8 },
        .{ 0x011b60, 0x011b67 },
        .{ 0x011bc0, 0x011be0 },
        .{ 0x011c00, 0x011c08 },
        .{ 0x011c0a, 0x011c36 },
        .{ 0x011c38, 0x011c3e },
        .{ 0x011c72, 0x011c8f },
        .{ 0x011c92, 0x011ca7 },
        .{ 0x011ca9, 0x011cb6 },
        .{ 0x011d00, 0x011d06 },
        .{ 0x011d08, 0x011d09 },
        .{ 0x011d0b, 0x011d36 },
        .{ 0x011d3c, 0x011d3d },
        .{ 0x011d3f, 0x011d41 },
        .{ 0x011d46, 0x011d47 },
        .{ 0x011d60, 0x011d65 },
        .{ 0x011d67, 0x011d68 },
        .{ 0x011d6a, 0x011d8e },
        .{ 0x011d90, 0x011d91 },
        .{ 0x011d93, 0x011d96 },
        .{ 0x011db0, 0x011ddb },
        .{ 0x011ee0, 0x011ef6 },
        .{ 0x011f00, 0x011f10 },
        .{ 0x011f12, 0x011f3a },
        .{ 0x011f3e, 0x011f40 },
        .{ 0x012000, 0x012399 },
        .{ 0x012400, 0x01246e },
        .{ 0x012480, 0x012543 },
        .{ 0x012f90, 0x012ff0 },
        .{ 0x013000, 0x01342f },
        .{ 0x013441, 0x013446 },
        .{ 0x013460, 0x0143fa },
        .{ 0x014400, 0x014646 },
        .{ 0x016100, 0x01612e },
        .{ 0x016800, 0x016a38 },
        .{ 0x016a40, 0x016a5e },
        .{ 0x016a70, 0x016abe },
        .{ 0x016ad0, 0x016aed },
        .{ 0x016b00, 0x016b2f },
        .{ 0x016b40, 0x016b43 },
        .{ 0x016b63, 0x016b77 },
        .{ 0x016b7d, 0x016b8f },
        .{ 0x016d40, 0x016d6c },
        .{ 0x016e40, 0x016e7f },
        .{ 0x016ea0, 0x016eb8 },
        .{ 0x016ebb, 0x016ed3 },
        .{ 0x016f00, 0x016f4a },
        .{ 0x016f4f, 0x016f87 },
        .{ 0x016f8f, 0x016f9f },
        .{ 0x016fe0, 0x016fe1 },
        .{ 0x016ff0, 0x016ff6 },
        .{ 0x017000, 0x018cd5 },
        .{ 0x018cff, 0x018d1e },
        .{ 0x018d80, 0x018df2 },
        .{ 0x01aff0, 0x01aff3 },
        .{ 0x01aff5, 0x01affb },
        .{ 0x01affd, 0x01affe },
        .{ 0x01b000, 0x01b122 },
        .{ 0x01b150, 0x01b152 },
        .{ 0x01b164, 0x01b167 },
        .{ 0x01b170, 0x01b2fb },
        .{ 0x01bc00, 0x01bc6a },
        .{ 0x01bc70, 0x01bc7c },
        .{ 0x01bc80, 0x01bc88 },
        .{ 0x01bc90, 0x01bc99 },
        .{ 0x01d400, 0x01d454 },
        .{ 0x01d456, 0x01d49c },
        .{ 0x01d49e, 0x01d49f },
        .{ 0x01d4a5, 0x01d4a6 },
        .{ 0x01d4a9, 0x01d4ac },
        .{ 0x01d4ae, 0x01d4b9 },
        .{ 0x01d4bd, 0x01d4c3 },
        .{ 0x01d4c5, 0x01d505 },
        .{ 0x01d507, 0x01d50a },
        .{ 0x01d50d, 0x01d514 },
        .{ 0x01d516, 0x01d51c },
        .{ 0x01d51e, 0x01d539 },
        .{ 0x01d53b, 0x01d53e },
        .{ 0x01d540, 0x01d544 },
        .{ 0x01d54a, 0x01d550 },
        .{ 0x01d552, 0x01d6a5 },
        .{ 0x01d6a8, 0x01d6c0 },
        .{ 0x01d6c2, 0x01d6da },
        .{ 0x01d6dc, 0x01d6fa },
        .{ 0x01d6fc, 0x01d714 },
        .{ 0x01d716, 0x01d734 },
        .{ 0x01d736, 0x01d74e },
        .{ 0x01d750, 0x01d76e },
        .{ 0x01d770, 0x01d788 },
        .{ 0x01d78a, 0x01d7a8 },
        .{ 0x01d7aa, 0x01d7c2 },
        .{ 0x01d7c4, 0x01d7cb },
        .{ 0x01df00, 0x01df1e },
        .{ 0x01df25, 0x01df2a },
        .{ 0x01e000, 0x01e006 },
        .{ 0x01e008, 0x01e018 },
        .{ 0x01e01b, 0x01e021 },
        .{ 0x01e023, 0x01e024 },
        .{ 0x01e026, 0x01e02a },
        .{ 0x01e030, 0x01e06d },
        .{ 0x01e100, 0x01e12c },
        .{ 0x01e137, 0x01e13d },
        .{ 0x01e290, 0x01e2ad },
        .{ 0x01e2c0, 0x01e2eb },
        .{ 0x01e4d0, 0x01e4eb },
        .{ 0x01e5d0, 0x01e5ed },
        .{ 0x01e6c0, 0x01e6de },
        .{ 0x01e6e0, 0x01e6f5 },
        .{ 0x01e6fe, 0x01e6ff },
        .{ 0x01e7e0, 0x01e7e6 },
        .{ 0x01e7e8, 0x01e7eb },
        .{ 0x01e7ed, 0x01e7ee },
        .{ 0x01e7f0, 0x01e7fe },
        .{ 0x01e800, 0x01e8c4 },
        .{ 0x01e900, 0x01e943 },
        .{ 0x01ee00, 0x01ee03 },
        .{ 0x01ee05, 0x01ee1f },
        .{ 0x01ee21, 0x01ee22 },
        .{ 0x01ee29, 0x01ee32 },
        .{ 0x01ee34, 0x01ee37 },
        .{ 0x01ee4d, 0x01ee4f },
        .{ 0x01ee51, 0x01ee52 },
        .{ 0x01ee61, 0x01ee62 },
        .{ 0x01ee67, 0x01ee6a },
        .{ 0x01ee6c, 0x01ee72 },
        .{ 0x01ee74, 0x01ee77 },
        .{ 0x01ee79, 0x01ee7c },
        .{ 0x01ee80, 0x01ee89 },
        .{ 0x01ee8b, 0x01ee9b },
        .{ 0x01eea1, 0x01eea3 },
        .{ 0x01eea5, 0x01eea9 },
        .{ 0x01eeab, 0x01eebb },
        .{ 0x01f130, 0x01f149 },
        .{ 0x01f150, 0x01f169 },
        .{ 0x01f170, 0x01f189 },
        .{ 0x020000, 0x02a6df },
        .{ 0x02a700, 0x02b81d },
        .{ 0x02b820, 0x02cead },
        .{ 0x02ceb0, 0x02ebe0 },
        .{ 0x02ebf0, 0x02ee5d },
        .{ 0x02f800, 0x02fa1d },
        .{ 0x030000, 0x03134a },
        .{ 0x031350, 0x033479 },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeCaseIgnorableCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000027, 0x00002e, 0x00003a, 0x00005e, 0x000060, 0x0000a8, 0x0000ad, 0x0000af,
        0x0000b4, 0x00037a, 0x000387, 0x000559, 0x00055f, 0x0005bf, 0x0005c7, 0x0005f4,
        0x00061c, 0x000640, 0x000670, 0x00070f, 0x000711, 0x0007fa, 0x0007fd, 0x000888,
        0x00093a, 0x00093c, 0x00094d, 0x000971, 0x000981, 0x0009bc, 0x0009cd, 0x0009fe,
        0x000a3c, 0x000a51, 0x000a75, 0x000abc, 0x000acd, 0x000b01, 0x000b3c, 0x000b3f,
        0x000b4d, 0x000b82, 0x000bc0, 0x000bcd, 0x000c00, 0x000c04, 0x000c3c, 0x000c81,
        0x000cbc, 0x000cbf, 0x000cc6, 0x000d4d, 0x000d81, 0x000dca, 0x000dd6, 0x000e31,
        0x000eb1, 0x000ec6, 0x000f35, 0x000f37, 0x000f39, 0x000fc6, 0x001082, 0x00108d,
        0x00109d, 0x0010fc, 0x0017c6, 0x0017d7, 0x0017dd, 0x001843, 0x0018a9, 0x001932,
        0x001a1b, 0x001a56, 0x001a60, 0x001a62, 0x001a7f, 0x001aa7, 0x001b34, 0x001b3c,
        0x001b42, 0x001be6, 0x001bed, 0x001ced, 0x001cf4, 0x001d78, 0x001fbd, 0x002024,
        0x002027, 0x002071, 0x00207f, 0x002d6f, 0x002d7f, 0x002e2f, 0x003005, 0x00303b,
        0x00a015, 0x00a60c, 0x00a67f, 0x00a770, 0x00a802, 0x00a806, 0x00a80b, 0x00a82c,
        0x00a8ff, 0x00a9b3, 0x00a9cf, 0x00aa43, 0x00aa4c, 0x00aa70, 0x00aa7c, 0x00aab0,
        0x00aac1, 0x00aadd, 0x00aaf6, 0x00abe5, 0x00abe8, 0x00abed, 0x00fb1e, 0x00fe13,
        0x00fe52, 0x00fe55, 0x00feff, 0x00ff07, 0x00ff0e, 0x00ff1a, 0x00ff3e, 0x00ff40,
        0x00ff70, 0x00ffe3, 0x0101fd, 0x0102e0, 0x010a3f, 0x010d4e, 0x010d6f, 0x010ec5,
        0x011001, 0x011070, 0x0110bd, 0x0110c2, 0x0110cd, 0x011173, 0x0111cf, 0x011234,
        0x01123e, 0x011241, 0x0112df, 0x011340, 0x0113ce, 0x0113d0, 0x0113d2, 0x011446,
        0x01145e, 0x0114ba, 0x01163d, 0x0116ab, 0x0116ad, 0x0116b7, 0x01171d, 0x01171f,
        0x01193e, 0x011943, 0x0119e0, 0x011a47, 0x011b60, 0x011b66, 0x011c3f, 0x011d3a,
        0x011d47, 0x011d95, 0x011d97, 0x011dd9, 0x011f40, 0x011f42, 0x011f5a, 0x016f4f,
        0x01da75, 0x01da84, 0x01e08f, 0x01e2ae, 0x01e6e3, 0x01e6e6, 0x01e6f5, 0x01e6ff,
        0x0e0001,
    };
    const ranges = [_][2]u21{
        .{ 0x0000b7, 0x0000b8 },
        .{ 0x0002b0, 0x00036f },
        .{ 0x000374, 0x000375 },
        .{ 0x000384, 0x000385 },
        .{ 0x000483, 0x000489 },
        .{ 0x000591, 0x0005bd },
        .{ 0x0005c1, 0x0005c2 },
        .{ 0x0005c4, 0x0005c5 },
        .{ 0x000600, 0x000605 },
        .{ 0x000610, 0x00061a },
        .{ 0x00064b, 0x00065f },
        .{ 0x0006d6, 0x0006dd },
        .{ 0x0006df, 0x0006e8 },
        .{ 0x0006ea, 0x0006ed },
        .{ 0x000730, 0x00074a },
        .{ 0x0007a6, 0x0007b0 },
        .{ 0x0007eb, 0x0007f5 },
        .{ 0x000816, 0x00082d },
        .{ 0x000859, 0x00085b },
        .{ 0x000890, 0x000891 },
        .{ 0x000897, 0x00089f },
        .{ 0x0008c9, 0x000902 },
        .{ 0x000941, 0x000948 },
        .{ 0x000951, 0x000957 },
        .{ 0x000962, 0x000963 },
        .{ 0x0009c1, 0x0009c4 },
        .{ 0x0009e2, 0x0009e3 },
        .{ 0x000a01, 0x000a02 },
        .{ 0x000a41, 0x000a42 },
        .{ 0x000a47, 0x000a48 },
        .{ 0x000a4b, 0x000a4d },
        .{ 0x000a70, 0x000a71 },
        .{ 0x000a81, 0x000a82 },
        .{ 0x000ac1, 0x000ac5 },
        .{ 0x000ac7, 0x000ac8 },
        .{ 0x000ae2, 0x000ae3 },
        .{ 0x000afa, 0x000aff },
        .{ 0x000b41, 0x000b44 },
        .{ 0x000b55, 0x000b56 },
        .{ 0x000b62, 0x000b63 },
        .{ 0x000c3e, 0x000c40 },
        .{ 0x000c46, 0x000c48 },
        .{ 0x000c4a, 0x000c4d },
        .{ 0x000c55, 0x000c56 },
        .{ 0x000c62, 0x000c63 },
        .{ 0x000ccc, 0x000ccd },
        .{ 0x000ce2, 0x000ce3 },
        .{ 0x000d00, 0x000d01 },
        .{ 0x000d3b, 0x000d3c },
        .{ 0x000d41, 0x000d44 },
        .{ 0x000d62, 0x000d63 },
        .{ 0x000dd2, 0x000dd4 },
        .{ 0x000e34, 0x000e3a },
        .{ 0x000e46, 0x000e4e },
        .{ 0x000eb4, 0x000ebc },
        .{ 0x000ec8, 0x000ece },
        .{ 0x000f18, 0x000f19 },
        .{ 0x000f71, 0x000f7e },
        .{ 0x000f80, 0x000f84 },
        .{ 0x000f86, 0x000f87 },
        .{ 0x000f8d, 0x000f97 },
        .{ 0x000f99, 0x000fbc },
        .{ 0x00102d, 0x001030 },
        .{ 0x001032, 0x001037 },
        .{ 0x001039, 0x00103a },
        .{ 0x00103d, 0x00103e },
        .{ 0x001058, 0x001059 },
        .{ 0x00105e, 0x001060 },
        .{ 0x001071, 0x001074 },
        .{ 0x001085, 0x001086 },
        .{ 0x00135d, 0x00135f },
        .{ 0x001712, 0x001714 },
        .{ 0x001732, 0x001733 },
        .{ 0x001752, 0x001753 },
        .{ 0x001772, 0x001773 },
        .{ 0x0017b4, 0x0017b5 },
        .{ 0x0017b7, 0x0017bd },
        .{ 0x0017c9, 0x0017d3 },
        .{ 0x00180b, 0x00180f },
        .{ 0x001885, 0x001886 },
        .{ 0x001920, 0x001922 },
        .{ 0x001927, 0x001928 },
        .{ 0x001939, 0x00193b },
        .{ 0x001a17, 0x001a18 },
        .{ 0x001a58, 0x001a5e },
        .{ 0x001a65, 0x001a6c },
        .{ 0x001a73, 0x001a7c },
        .{ 0x001ab0, 0x001add },
        .{ 0x001ae0, 0x001aeb },
        .{ 0x001b00, 0x001b03 },
        .{ 0x001b36, 0x001b3a },
        .{ 0x001b6b, 0x001b73 },
        .{ 0x001b80, 0x001b81 },
        .{ 0x001ba2, 0x001ba5 },
        .{ 0x001ba8, 0x001ba9 },
        .{ 0x001bab, 0x001bad },
        .{ 0x001be8, 0x001be9 },
        .{ 0x001bef, 0x001bf1 },
        .{ 0x001c2c, 0x001c33 },
        .{ 0x001c36, 0x001c37 },
        .{ 0x001c78, 0x001c7d },
        .{ 0x001cd0, 0x001cd2 },
        .{ 0x001cd4, 0x001ce0 },
        .{ 0x001ce2, 0x001ce8 },
        .{ 0x001cf8, 0x001cf9 },
        .{ 0x001d2c, 0x001d6a },
        .{ 0x001d9b, 0x001dff },
        .{ 0x001fbf, 0x001fc1 },
        .{ 0x001fcd, 0x001fcf },
        .{ 0x001fdd, 0x001fdf },
        .{ 0x001fed, 0x001fef },
        .{ 0x001ffd, 0x001ffe },
        .{ 0x00200b, 0x00200f },
        .{ 0x002018, 0x002019 },
        .{ 0x00202a, 0x00202e },
        .{ 0x002060, 0x002064 },
        .{ 0x002066, 0x00206f },
        .{ 0x002090, 0x00209c },
        .{ 0x0020d0, 0x0020f0 },
        .{ 0x002c7c, 0x002c7d },
        .{ 0x002cef, 0x002cf1 },
        .{ 0x002de0, 0x002dff },
        .{ 0x00302a, 0x00302d },
        .{ 0x003031, 0x003035 },
        .{ 0x003099, 0x00309e },
        .{ 0x0030fc, 0x0030fe },
        .{ 0x00a4f8, 0x00a4fd },
        .{ 0x00a66f, 0x00a672 },
        .{ 0x00a674, 0x00a67d },
        .{ 0x00a69c, 0x00a69f },
        .{ 0x00a6f0, 0x00a6f1 },
        .{ 0x00a700, 0x00a721 },
        .{ 0x00a788, 0x00a78a },
        .{ 0x00a7f1, 0x00a7f4 },
        .{ 0x00a7f8, 0x00a7f9 },
        .{ 0x00a825, 0x00a826 },
        .{ 0x00a8c4, 0x00a8c5 },
        .{ 0x00a8e0, 0x00a8f1 },
        .{ 0x00a926, 0x00a92d },
        .{ 0x00a947, 0x00a951 },
        .{ 0x00a980, 0x00a982 },
        .{ 0x00a9b6, 0x00a9b9 },
        .{ 0x00a9bc, 0x00a9bd },
        .{ 0x00a9e5, 0x00a9e6 },
        .{ 0x00aa29, 0x00aa2e },
        .{ 0x00aa31, 0x00aa32 },
        .{ 0x00aa35, 0x00aa36 },
        .{ 0x00aab2, 0x00aab4 },
        .{ 0x00aab7, 0x00aab8 },
        .{ 0x00aabe, 0x00aabf },
        .{ 0x00aaec, 0x00aaed },
        .{ 0x00aaf3, 0x00aaf4 },
        .{ 0x00ab5b, 0x00ab5f },
        .{ 0x00ab69, 0x00ab6b },
        .{ 0x00fbb2, 0x00fbc2 },
        .{ 0x00fe00, 0x00fe0f },
        .{ 0x00fe20, 0x00fe2f },
        .{ 0x00ff9e, 0x00ff9f },
        .{ 0x00fff9, 0x00fffb },
        .{ 0x010376, 0x01037a },
        .{ 0x010780, 0x010785 },
        .{ 0x010787, 0x0107b0 },
        .{ 0x0107b2, 0x0107ba },
        .{ 0x010a01, 0x010a03 },
        .{ 0x010a05, 0x010a06 },
        .{ 0x010a0c, 0x010a0f },
        .{ 0x010a38, 0x010a3a },
        .{ 0x010ae5, 0x010ae6 },
        .{ 0x010d24, 0x010d27 },
        .{ 0x010d69, 0x010d6d },
        .{ 0x010eab, 0x010eac },
        .{ 0x010efa, 0x010eff },
        .{ 0x010f46, 0x010f50 },
        .{ 0x010f82, 0x010f85 },
        .{ 0x011038, 0x011046 },
        .{ 0x011073, 0x011074 },
        .{ 0x01107f, 0x011081 },
        .{ 0x0110b3, 0x0110b6 },
        .{ 0x0110b9, 0x0110ba },
        .{ 0x011100, 0x011102 },
        .{ 0x011127, 0x01112b },
        .{ 0x01112d, 0x011134 },
        .{ 0x011180, 0x011181 },
        .{ 0x0111b6, 0x0111be },
        .{ 0x0111c9, 0x0111cc },
        .{ 0x01122f, 0x011231 },
        .{ 0x011236, 0x011237 },
        .{ 0x0112e3, 0x0112ea },
        .{ 0x011300, 0x011301 },
        .{ 0x01133b, 0x01133c },
        .{ 0x011366, 0x01136c },
        .{ 0x011370, 0x011374 },
        .{ 0x0113bb, 0x0113c0 },
        .{ 0x0113e1, 0x0113e2 },
        .{ 0x011438, 0x01143f },
        .{ 0x011442, 0x011444 },
        .{ 0x0114b3, 0x0114b8 },
        .{ 0x0114bf, 0x0114c0 },
        .{ 0x0114c2, 0x0114c3 },
        .{ 0x0115b2, 0x0115b5 },
        .{ 0x0115bc, 0x0115bd },
        .{ 0x0115bf, 0x0115c0 },
        .{ 0x0115dc, 0x0115dd },
        .{ 0x011633, 0x01163a },
        .{ 0x01163f, 0x011640 },
        .{ 0x0116b0, 0x0116b5 },
        .{ 0x011722, 0x011725 },
        .{ 0x011727, 0x01172b },
        .{ 0x01182f, 0x011837 },
        .{ 0x011839, 0x01183a },
        .{ 0x01193b, 0x01193c },
        .{ 0x0119d4, 0x0119d7 },
        .{ 0x0119da, 0x0119db },
        .{ 0x011a01, 0x011a0a },
        .{ 0x011a33, 0x011a38 },
        .{ 0x011a3b, 0x011a3e },
        .{ 0x011a51, 0x011a56 },
        .{ 0x011a59, 0x011a5b },
        .{ 0x011a8a, 0x011a96 },
        .{ 0x011a98, 0x011a99 },
        .{ 0x011b62, 0x011b64 },
        .{ 0x011c30, 0x011c36 },
        .{ 0x011c38, 0x011c3d },
        .{ 0x011c92, 0x011ca7 },
        .{ 0x011caa, 0x011cb0 },
        .{ 0x011cb2, 0x011cb3 },
        .{ 0x011cb5, 0x011cb6 },
        .{ 0x011d31, 0x011d36 },
        .{ 0x011d3c, 0x011d3d },
        .{ 0x011d3f, 0x011d45 },
        .{ 0x011d90, 0x011d91 },
        .{ 0x011ef3, 0x011ef4 },
        .{ 0x011f00, 0x011f01 },
        .{ 0x011f36, 0x011f3a },
        .{ 0x013430, 0x013440 },
        .{ 0x013447, 0x013455 },
        .{ 0x01611e, 0x016129 },
        .{ 0x01612d, 0x01612f },
        .{ 0x016af0, 0x016af4 },
        .{ 0x016b30, 0x016b36 },
        .{ 0x016b40, 0x016b43 },
        .{ 0x016d40, 0x016d42 },
        .{ 0x016d6b, 0x016d6c },
        .{ 0x016f8f, 0x016f9f },
        .{ 0x016fe0, 0x016fe1 },
        .{ 0x016fe3, 0x016fe4 },
        .{ 0x016ff2, 0x016ff3 },
        .{ 0x01aff0, 0x01aff3 },
        .{ 0x01aff5, 0x01affb },
        .{ 0x01affd, 0x01affe },
        .{ 0x01bc9d, 0x01bc9e },
        .{ 0x01bca0, 0x01bca3 },
        .{ 0x01cf00, 0x01cf2d },
        .{ 0x01cf30, 0x01cf46 },
        .{ 0x01d167, 0x01d169 },
        .{ 0x01d173, 0x01d182 },
        .{ 0x01d185, 0x01d18b },
        .{ 0x01d1aa, 0x01d1ad },
        .{ 0x01d242, 0x01d244 },
        .{ 0x01da00, 0x01da36 },
        .{ 0x01da3b, 0x01da6c },
        .{ 0x01da9b, 0x01da9f },
        .{ 0x01daa1, 0x01daaf },
        .{ 0x01e000, 0x01e006 },
        .{ 0x01e008, 0x01e018 },
        .{ 0x01e01b, 0x01e021 },
        .{ 0x01e023, 0x01e024 },
        .{ 0x01e026, 0x01e02a },
        .{ 0x01e030, 0x01e06d },
        .{ 0x01e130, 0x01e13d },
        .{ 0x01e2ec, 0x01e2ef },
        .{ 0x01e4eb, 0x01e4ef },
        .{ 0x01e5ee, 0x01e5ef },
        .{ 0x01e6ee, 0x01e6ef },
        .{ 0x01e8d0, 0x01e8d6 },
        .{ 0x01e944, 0x01e94b },
        .{ 0x01f3fb, 0x01f3ff },
        .{ 0x0e0020, 0x0e007f },
        .{ 0x0e0100, 0x0e01ef },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeChangesWhenCasemappedCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000b5, 0x0001bf, 0x000259, 0x00026f, 0x000275, 0x00027d, 0x000280, 0x000292,
        0x000345, 0x00037f, 0x000386, 0x00038c, 0x0010c7, 0x0010cd, 0x001d79, 0x001d7d,
        0x001d8e, 0x001e9e, 0x001f59, 0x001f5b, 0x001f5d, 0x001fbe, 0x002126, 0x002132,
        0x00214e, 0x002d27, 0x002d2d, 0x00ab53,
    };
    const ranges = [_][2]u21{
        .{ 0x000041, 0x00005a },
        .{ 0x000061, 0x00007a },
        .{ 0x0000c0, 0x0000d6 },
        .{ 0x0000d8, 0x0000f6 },
        .{ 0x0000f8, 0x000137 },
        .{ 0x000139, 0x00018c },
        .{ 0x00018e, 0x0001a9 },
        .{ 0x0001ac, 0x0001b9 },
        .{ 0x0001bc, 0x0001bd },
        .{ 0x0001c4, 0x000220 },
        .{ 0x000222, 0x000233 },
        .{ 0x00023a, 0x000254 },
        .{ 0x000256, 0x000257 },
        .{ 0x00025b, 0x00025c },
        .{ 0x000260, 0x000261 },
        .{ 0x000263, 0x000266 },
        .{ 0x000268, 0x00026c },
        .{ 0x000271, 0x000272 },
        .{ 0x000282, 0x000283 },
        .{ 0x000287, 0x00028c },
        .{ 0x00029d, 0x00029e },
        .{ 0x000370, 0x000373 },
        .{ 0x000376, 0x000377 },
        .{ 0x00037b, 0x00037d },
        .{ 0x000388, 0x00038a },
        .{ 0x00038e, 0x0003a1 },
        .{ 0x0003a3, 0x0003d1 },
        .{ 0x0003d5, 0x0003f5 },
        .{ 0x0003f7, 0x0003fb },
        .{ 0x0003fd, 0x000481 },
        .{ 0x00048a, 0x00052f },
        .{ 0x000531, 0x000556 },
        .{ 0x000561, 0x000587 },
        .{ 0x0010a0, 0x0010c5 },
        .{ 0x0010d0, 0x0010fa },
        .{ 0x0010fd, 0x0010ff },
        .{ 0x0013a0, 0x0013f5 },
        .{ 0x0013f8, 0x0013fd },
        .{ 0x001c80, 0x001c8a },
        .{ 0x001c90, 0x001cba },
        .{ 0x001cbd, 0x001cbf },
        .{ 0x001e00, 0x001e9b },
        .{ 0x001ea0, 0x001f15 },
        .{ 0x001f18, 0x001f1d },
        .{ 0x001f20, 0x001f45 },
        .{ 0x001f48, 0x001f4d },
        .{ 0x001f50, 0x001f57 },
        .{ 0x001f5f, 0x001f7d },
        .{ 0x001f80, 0x001fb4 },
        .{ 0x001fb6, 0x001fbc },
        .{ 0x001fc2, 0x001fc4 },
        .{ 0x001fc6, 0x001fcc },
        .{ 0x001fd0, 0x001fd3 },
        .{ 0x001fd6, 0x001fdb },
        .{ 0x001fe0, 0x001fec },
        .{ 0x001ff2, 0x001ff4 },
        .{ 0x001ff6, 0x001ffc },
        .{ 0x00212a, 0x00212b },
        .{ 0x002160, 0x00217f },
        .{ 0x002183, 0x002184 },
        .{ 0x0024b6, 0x0024e9 },
        .{ 0x002c00, 0x002c70 },
        .{ 0x002c72, 0x002c73 },
        .{ 0x002c75, 0x002c76 },
        .{ 0x002c7e, 0x002ce3 },
        .{ 0x002ceb, 0x002cee },
        .{ 0x002cf2, 0x002cf3 },
        .{ 0x002d00, 0x002d25 },
        .{ 0x00a640, 0x00a66d },
        .{ 0x00a680, 0x00a69b },
        .{ 0x00a722, 0x00a72f },
        .{ 0x00a732, 0x00a76f },
        .{ 0x00a779, 0x00a787 },
        .{ 0x00a78b, 0x00a78d },
        .{ 0x00a790, 0x00a794 },
        .{ 0x00a796, 0x00a7ae },
        .{ 0x00a7b0, 0x00a7dc },
        .{ 0x00a7f5, 0x00a7f6 },
        .{ 0x00ab70, 0x00abbf },
        .{ 0x00fb00, 0x00fb06 },
        .{ 0x00fb13, 0x00fb17 },
        .{ 0x00ff21, 0x00ff3a },
        .{ 0x00ff41, 0x00ff5a },
        .{ 0x010400, 0x01044f },
        .{ 0x0104b0, 0x0104d3 },
        .{ 0x0104d8, 0x0104fb },
        .{ 0x010570, 0x01057a },
        .{ 0x01057c, 0x01058a },
        .{ 0x01058c, 0x010592 },
        .{ 0x010594, 0x010595 },
        .{ 0x010597, 0x0105a1 },
        .{ 0x0105a3, 0x0105b1 },
        .{ 0x0105b3, 0x0105b9 },
        .{ 0x0105bb, 0x0105bc },
        .{ 0x010c80, 0x010cb2 },
        .{ 0x010cc0, 0x010cf2 },
        .{ 0x010d50, 0x010d65 },
        .{ 0x010d70, 0x010d85 },
        .{ 0x0118a0, 0x0118df },
        .{ 0x016e40, 0x016e7f },
        .{ 0x016ea0, 0x016eb8 },
        .{ 0x016ebb, 0x016ed3 },
        .{ 0x01e900, 0x01e943 },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeChangesWhenCasefoldedCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000b5, 0x000100, 0x000102, 0x000104, 0x000106, 0x000108, 0x00010a, 0x00010c,
        0x00010e, 0x000110, 0x000112, 0x000114, 0x000116, 0x000118, 0x00011a, 0x00011c,
        0x00011e, 0x000120, 0x000122, 0x000124, 0x000126, 0x000128, 0x00012a, 0x00012c,
        0x00012e, 0x000130, 0x000132, 0x000134, 0x000136, 0x000139, 0x00013b, 0x00013d,
        0x00013f, 0x000141, 0x000143, 0x000145, 0x000147, 0x00014c, 0x00014e, 0x000150,
        0x000152, 0x000154, 0x000156, 0x000158, 0x00015a, 0x00015c, 0x00015e, 0x000160,
        0x000162, 0x000164, 0x000166, 0x000168, 0x00016a, 0x00016c, 0x00016e, 0x000170,
        0x000172, 0x000174, 0x000176, 0x00017b, 0x00017d, 0x00017f, 0x000184, 0x0001a2,
        0x0001a4, 0x0001a9, 0x0001ac, 0x0001b5, 0x0001bc, 0x0001cd, 0x0001cf, 0x0001d1,
        0x0001d3, 0x0001d5, 0x0001d7, 0x0001d9, 0x0001db, 0x0001de, 0x0001e0, 0x0001e2,
        0x0001e4, 0x0001e6, 0x0001e8, 0x0001ea, 0x0001ec, 0x0001ee, 0x0001f4, 0x0001fa,
        0x0001fc, 0x0001fe, 0x000200, 0x000202, 0x000204, 0x000206, 0x000208, 0x00020a,
        0x00020c, 0x00020e, 0x000210, 0x000212, 0x000214, 0x000216, 0x000218, 0x00021a,
        0x00021c, 0x00021e, 0x000220, 0x000222, 0x000224, 0x000226, 0x000228, 0x00022a,
        0x00022c, 0x00022e, 0x000230, 0x000232, 0x000241, 0x000248, 0x00024a, 0x00024c,
        0x00024e, 0x000345, 0x000370, 0x000372, 0x000376, 0x00037f, 0x000386, 0x00038c,
        0x0003c2, 0x0003d8, 0x0003da, 0x0003dc, 0x0003de, 0x0003e0, 0x0003e2, 0x0003e4,
        0x0003e6, 0x0003e8, 0x0003ea, 0x0003ec, 0x0003ee, 0x0003f7, 0x000460, 0x000462,
        0x000464, 0x000466, 0x000468, 0x00046a, 0x00046c, 0x00046e, 0x000470, 0x000472,
        0x000474, 0x000476, 0x000478, 0x00047a, 0x00047c, 0x00047e, 0x000480, 0x00048a,
        0x00048c, 0x00048e, 0x000490, 0x000492, 0x000494, 0x000496, 0x000498, 0x00049a,
        0x00049c, 0x00049e, 0x0004a0, 0x0004a2, 0x0004a4, 0x0004a6, 0x0004a8, 0x0004aa,
        0x0004ac, 0x0004ae, 0x0004b0, 0x0004b2, 0x0004b4, 0x0004b6, 0x0004b8, 0x0004ba,
        0x0004bc, 0x0004be, 0x0004c3, 0x0004c5, 0x0004c7, 0x0004c9, 0x0004cb, 0x0004cd,
        0x0004d0, 0x0004d2, 0x0004d4, 0x0004d6, 0x0004d8, 0x0004da, 0x0004dc, 0x0004de,
        0x0004e0, 0x0004e2, 0x0004e4, 0x0004e6, 0x0004e8, 0x0004ea, 0x0004ec, 0x0004ee,
        0x0004f0, 0x0004f2, 0x0004f4, 0x0004f6, 0x0004f8, 0x0004fa, 0x0004fc, 0x0004fe,
        0x000500, 0x000502, 0x000504, 0x000506, 0x000508, 0x00050a, 0x00050c, 0x00050e,
        0x000510, 0x000512, 0x000514, 0x000516, 0x000518, 0x00051a, 0x00051c, 0x00051e,
        0x000520, 0x000522, 0x000524, 0x000526, 0x000528, 0x00052a, 0x00052c, 0x00052e,
        0x000587, 0x0010c7, 0x0010cd, 0x001e00, 0x001e02, 0x001e04, 0x001e06, 0x001e08,
        0x001e0a, 0x001e0c, 0x001e0e, 0x001e10, 0x001e12, 0x001e14, 0x001e16, 0x001e18,
        0x001e1a, 0x001e1c, 0x001e1e, 0x001e20, 0x001e22, 0x001e24, 0x001e26, 0x001e28,
        0x001e2a, 0x001e2c, 0x001e2e, 0x001e30, 0x001e32, 0x001e34, 0x001e36, 0x001e38,
        0x001e3a, 0x001e3c, 0x001e3e, 0x001e40, 0x001e42, 0x001e44, 0x001e46, 0x001e48,
        0x001e4a, 0x001e4c, 0x001e4e, 0x001e50, 0x001e52, 0x001e54, 0x001e56, 0x001e58,
        0x001e5a, 0x001e5c, 0x001e5e, 0x001e60, 0x001e62, 0x001e64, 0x001e66, 0x001e68,
        0x001e6a, 0x001e6c, 0x001e6e, 0x001e70, 0x001e72, 0x001e74, 0x001e76, 0x001e78,
        0x001e7a, 0x001e7c, 0x001e7e, 0x001e80, 0x001e82, 0x001e84, 0x001e86, 0x001e88,
        0x001e8a, 0x001e8c, 0x001e8e, 0x001e90, 0x001e92, 0x001e94, 0x001e9e, 0x001ea0,
        0x001ea2, 0x001ea4, 0x001ea6, 0x001ea8, 0x001eaa, 0x001eac, 0x001eae, 0x001eb0,
        0x001eb2, 0x001eb4, 0x001eb6, 0x001eb8, 0x001eba, 0x001ebc, 0x001ebe, 0x001ec0,
        0x001ec2, 0x001ec4, 0x001ec6, 0x001ec8, 0x001eca, 0x001ecc, 0x001ece, 0x001ed0,
        0x001ed2, 0x001ed4, 0x001ed6, 0x001ed8, 0x001eda, 0x001edc, 0x001ede, 0x001ee0,
        0x001ee2, 0x001ee4, 0x001ee6, 0x001ee8, 0x001eea, 0x001eec, 0x001eee, 0x001ef0,
        0x001ef2, 0x001ef4, 0x001ef6, 0x001ef8, 0x001efa, 0x001efc, 0x001efe, 0x001f59,
        0x001f5b, 0x001f5d, 0x001f5f, 0x002126, 0x002132, 0x002183, 0x002c60, 0x002c67,
        0x002c69, 0x002c6b, 0x002c72, 0x002c75, 0x002c82, 0x002c84, 0x002c86, 0x002c88,
        0x002c8a, 0x002c8c, 0x002c8e, 0x002c90, 0x002c92, 0x002c94, 0x002c96, 0x002c98,
        0x002c9a, 0x002c9c, 0x002c9e, 0x002ca0, 0x002ca2, 0x002ca4, 0x002ca6, 0x002ca8,
        0x002caa, 0x002cac, 0x002cae, 0x002cb0, 0x002cb2, 0x002cb4, 0x002cb6, 0x002cb8,
        0x002cba, 0x002cbc, 0x002cbe, 0x002cc0, 0x002cc2, 0x002cc4, 0x002cc6, 0x002cc8,
        0x002cca, 0x002ccc, 0x002cce, 0x002cd0, 0x002cd2, 0x002cd4, 0x002cd6, 0x002cd8,
        0x002cda, 0x002cdc, 0x002cde, 0x002ce0, 0x002ce2, 0x002ceb, 0x002ced, 0x002cf2,
        0x00a640, 0x00a642, 0x00a644, 0x00a646, 0x00a648, 0x00a64a, 0x00a64c, 0x00a64e,
        0x00a650, 0x00a652, 0x00a654, 0x00a656, 0x00a658, 0x00a65a, 0x00a65c, 0x00a65e,
        0x00a660, 0x00a662, 0x00a664, 0x00a666, 0x00a668, 0x00a66a, 0x00a66c, 0x00a680,
        0x00a682, 0x00a684, 0x00a686, 0x00a688, 0x00a68a, 0x00a68c, 0x00a68e, 0x00a690,
        0x00a692, 0x00a694, 0x00a696, 0x00a698, 0x00a69a, 0x00a722, 0x00a724, 0x00a726,
        0x00a728, 0x00a72a, 0x00a72c, 0x00a72e, 0x00a732, 0x00a734, 0x00a736, 0x00a738,
        0x00a73a, 0x00a73c, 0x00a73e, 0x00a740, 0x00a742, 0x00a744, 0x00a746, 0x00a748,
        0x00a74a, 0x00a74c, 0x00a74e, 0x00a750, 0x00a752, 0x00a754, 0x00a756, 0x00a758,
        0x00a75a, 0x00a75c, 0x00a75e, 0x00a760, 0x00a762, 0x00a764, 0x00a766, 0x00a768,
        0x00a76a, 0x00a76c, 0x00a76e, 0x00a779, 0x00a77b, 0x00a780, 0x00a782, 0x00a784,
        0x00a786, 0x00a78b, 0x00a78d, 0x00a790, 0x00a792, 0x00a796, 0x00a798, 0x00a79a,
        0x00a79c, 0x00a79e, 0x00a7a0, 0x00a7a2, 0x00a7a4, 0x00a7a6, 0x00a7a8, 0x00a7b6,
        0x00a7b8, 0x00a7ba, 0x00a7bc, 0x00a7be, 0x00a7c0, 0x00a7c2, 0x00a7c9, 0x00a7ce,
        0x00a7d0, 0x00a7d2, 0x00a7d4, 0x00a7d6, 0x00a7d8, 0x00a7da, 0x00a7dc, 0x00a7f5,
    };
    const ranges = [_][2]u21{
        .{ 0x000041, 0x00005a },
        .{ 0x0000c0, 0x0000d6 },
        .{ 0x0000d8, 0x0000df },
        .{ 0x000149, 0x00014a },
        .{ 0x000178, 0x000179 },
        .{ 0x000181, 0x000182 },
        .{ 0x000186, 0x000187 },
        .{ 0x000189, 0x00018b },
        .{ 0x00018e, 0x000191 },
        .{ 0x000193, 0x000194 },
        .{ 0x000196, 0x000198 },
        .{ 0x00019c, 0x00019d },
        .{ 0x00019f, 0x0001a0 },
        .{ 0x0001a6, 0x0001a7 },
        .{ 0x0001ae, 0x0001af },
        .{ 0x0001b1, 0x0001b3 },
        .{ 0x0001b7, 0x0001b8 },
        .{ 0x0001c4, 0x0001c5 },
        .{ 0x0001c7, 0x0001c8 },
        .{ 0x0001ca, 0x0001cb },
        .{ 0x0001f1, 0x0001f2 },
        .{ 0x0001f6, 0x0001f8 },
        .{ 0x00023a, 0x00023b },
        .{ 0x00023d, 0x00023e },
        .{ 0x000243, 0x000246 },
        .{ 0x000388, 0x00038a },
        .{ 0x00038e, 0x00038f },
        .{ 0x000391, 0x0003a1 },
        .{ 0x0003a3, 0x0003ab },
        .{ 0x0003cf, 0x0003d1 },
        .{ 0x0003d5, 0x0003d6 },
        .{ 0x0003f0, 0x0003f1 },
        .{ 0x0003f4, 0x0003f5 },
        .{ 0x0003f9, 0x0003fa },
        .{ 0x0003fd, 0x00042f },
        .{ 0x0004c0, 0x0004c1 },
        .{ 0x000531, 0x000556 },
        .{ 0x0010a0, 0x0010c5 },
        .{ 0x0013f8, 0x0013fd },
        .{ 0x001c80, 0x001c89 },
        .{ 0x001c90, 0x001cba },
        .{ 0x001cbd, 0x001cbf },
        .{ 0x001e9a, 0x001e9b },
        .{ 0x001f08, 0x001f0f },
        .{ 0x001f18, 0x001f1d },
        .{ 0x001f28, 0x001f2f },
        .{ 0x001f38, 0x001f3f },
        .{ 0x001f48, 0x001f4d },
        .{ 0x001f68, 0x001f6f },
        .{ 0x001f80, 0x001faf },
        .{ 0x001fb2, 0x001fb4 },
        .{ 0x001fb7, 0x001fbc },
        .{ 0x001fc2, 0x001fc4 },
        .{ 0x001fc7, 0x001fcc },
        .{ 0x001fd8, 0x001fdb },
        .{ 0x001fe8, 0x001fec },
        .{ 0x001ff2, 0x001ff4 },
        .{ 0x001ff7, 0x001ffc },
        .{ 0x00212a, 0x00212b },
        .{ 0x002160, 0x00216f },
        .{ 0x0024b6, 0x0024cf },
        .{ 0x002c00, 0x002c2f },
        .{ 0x002c62, 0x002c64 },
        .{ 0x002c6d, 0x002c70 },
        .{ 0x002c7e, 0x002c80 },
        .{ 0x00a77d, 0x00a77e },
        .{ 0x00a7aa, 0x00a7ae },
        .{ 0x00a7b0, 0x00a7b4 },
        .{ 0x00a7c4, 0x00a7c7 },
        .{ 0x00a7cb, 0x00a7cc },
        .{ 0x00ab70, 0x00abbf },
        .{ 0x00fb00, 0x00fb06 },
        .{ 0x00fb13, 0x00fb17 },
        .{ 0x00ff21, 0x00ff3a },
        .{ 0x010400, 0x010427 },
        .{ 0x0104b0, 0x0104d3 },
        .{ 0x010570, 0x01057a },
        .{ 0x01057c, 0x01058a },
        .{ 0x01058c, 0x010592 },
        .{ 0x010594, 0x010595 },
        .{ 0x010c80, 0x010cb2 },
        .{ 0x010d50, 0x010d65 },
        .{ 0x0118a0, 0x0118bf },
        .{ 0x016e40, 0x016e5f },
        .{ 0x016ea0, 0x016eb8 },
        .{ 0x01e900, 0x01e921 },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeChangesWhenLowercasedCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000100, 0x000102, 0x000104, 0x000106, 0x000108, 0x00010a, 0x00010c, 0x00010e,
        0x000110, 0x000112, 0x000114, 0x000116, 0x000118, 0x00011a, 0x00011c, 0x00011e,
        0x000120, 0x000122, 0x000124, 0x000126, 0x000128, 0x00012a, 0x00012c, 0x00012e,
        0x000130, 0x000132, 0x000134, 0x000136, 0x000139, 0x00013b, 0x00013d, 0x00013f,
        0x000141, 0x000143, 0x000145, 0x000147, 0x00014a, 0x00014c, 0x00014e, 0x000150,
        0x000152, 0x000154, 0x000156, 0x000158, 0x00015a, 0x00015c, 0x00015e, 0x000160,
        0x000162, 0x000164, 0x000166, 0x000168, 0x00016a, 0x00016c, 0x00016e, 0x000170,
        0x000172, 0x000174, 0x000176, 0x00017b, 0x00017d, 0x000184, 0x0001a2, 0x0001a4,
        0x0001a9, 0x0001ac, 0x0001b5, 0x0001bc, 0x0001cd, 0x0001cf, 0x0001d1, 0x0001d3,
        0x0001d5, 0x0001d7, 0x0001d9, 0x0001db, 0x0001de, 0x0001e0, 0x0001e2, 0x0001e4,
        0x0001e6, 0x0001e8, 0x0001ea, 0x0001ec, 0x0001ee, 0x0001f4, 0x0001fa, 0x0001fc,
        0x0001fe, 0x000200, 0x000202, 0x000204, 0x000206, 0x000208, 0x00020a, 0x00020c,
        0x00020e, 0x000210, 0x000212, 0x000214, 0x000216, 0x000218, 0x00021a, 0x00021c,
        0x00021e, 0x000220, 0x000222, 0x000224, 0x000226, 0x000228, 0x00022a, 0x00022c,
        0x00022e, 0x000230, 0x000232, 0x000241, 0x000248, 0x00024a, 0x00024c, 0x00024e,
        0x000370, 0x000372, 0x000376, 0x00037f, 0x000386, 0x00038c, 0x0003cf, 0x0003d8,
        0x0003da, 0x0003dc, 0x0003de, 0x0003e0, 0x0003e2, 0x0003e4, 0x0003e6, 0x0003e8,
        0x0003ea, 0x0003ec, 0x0003ee, 0x0003f4, 0x0003f7, 0x000460, 0x000462, 0x000464,
        0x000466, 0x000468, 0x00046a, 0x00046c, 0x00046e, 0x000470, 0x000472, 0x000474,
        0x000476, 0x000478, 0x00047a, 0x00047c, 0x00047e, 0x000480, 0x00048a, 0x00048c,
        0x00048e, 0x000490, 0x000492, 0x000494, 0x000496, 0x000498, 0x00049a, 0x00049c,
        0x00049e, 0x0004a0, 0x0004a2, 0x0004a4, 0x0004a6, 0x0004a8, 0x0004aa, 0x0004ac,
        0x0004ae, 0x0004b0, 0x0004b2, 0x0004b4, 0x0004b6, 0x0004b8, 0x0004ba, 0x0004bc,
        0x0004be, 0x0004c3, 0x0004c5, 0x0004c7, 0x0004c9, 0x0004cb, 0x0004cd, 0x0004d0,
        0x0004d2, 0x0004d4, 0x0004d6, 0x0004d8, 0x0004da, 0x0004dc, 0x0004de, 0x0004e0,
        0x0004e2, 0x0004e4, 0x0004e6, 0x0004e8, 0x0004ea, 0x0004ec, 0x0004ee, 0x0004f0,
        0x0004f2, 0x0004f4, 0x0004f6, 0x0004f8, 0x0004fa, 0x0004fc, 0x0004fe, 0x000500,
        0x000502, 0x000504, 0x000506, 0x000508, 0x00050a, 0x00050c, 0x00050e, 0x000510,
        0x000512, 0x000514, 0x000516, 0x000518, 0x00051a, 0x00051c, 0x00051e, 0x000520,
        0x000522, 0x000524, 0x000526, 0x000528, 0x00052a, 0x00052c, 0x00052e, 0x0010c7,
        0x0010cd, 0x001c89, 0x001e00, 0x001e02, 0x001e04, 0x001e06, 0x001e08, 0x001e0a,
        0x001e0c, 0x001e0e, 0x001e10, 0x001e12, 0x001e14, 0x001e16, 0x001e18, 0x001e1a,
        0x001e1c, 0x001e1e, 0x001e20, 0x001e22, 0x001e24, 0x001e26, 0x001e28, 0x001e2a,
        0x001e2c, 0x001e2e, 0x001e30, 0x001e32, 0x001e34, 0x001e36, 0x001e38, 0x001e3a,
        0x001e3c, 0x001e3e, 0x001e40, 0x001e42, 0x001e44, 0x001e46, 0x001e48, 0x001e4a,
        0x001e4c, 0x001e4e, 0x001e50, 0x001e52, 0x001e54, 0x001e56, 0x001e58, 0x001e5a,
        0x001e5c, 0x001e5e, 0x001e60, 0x001e62, 0x001e64, 0x001e66, 0x001e68, 0x001e6a,
        0x001e6c, 0x001e6e, 0x001e70, 0x001e72, 0x001e74, 0x001e76, 0x001e78, 0x001e7a,
        0x001e7c, 0x001e7e, 0x001e80, 0x001e82, 0x001e84, 0x001e86, 0x001e88, 0x001e8a,
        0x001e8c, 0x001e8e, 0x001e90, 0x001e92, 0x001e94, 0x001e9e, 0x001ea0, 0x001ea2,
        0x001ea4, 0x001ea6, 0x001ea8, 0x001eaa, 0x001eac, 0x001eae, 0x001eb0, 0x001eb2,
        0x001eb4, 0x001eb6, 0x001eb8, 0x001eba, 0x001ebc, 0x001ebe, 0x001ec0, 0x001ec2,
        0x001ec4, 0x001ec6, 0x001ec8, 0x001eca, 0x001ecc, 0x001ece, 0x001ed0, 0x001ed2,
        0x001ed4, 0x001ed6, 0x001ed8, 0x001eda, 0x001edc, 0x001ede, 0x001ee0, 0x001ee2,
        0x001ee4, 0x001ee6, 0x001ee8, 0x001eea, 0x001eec, 0x001eee, 0x001ef0, 0x001ef2,
        0x001ef4, 0x001ef6, 0x001ef8, 0x001efa, 0x001efc, 0x001efe, 0x001f59, 0x001f5b,
        0x001f5d, 0x001f5f, 0x002126, 0x002132, 0x002183, 0x002c60, 0x002c67, 0x002c69,
        0x002c6b, 0x002c72, 0x002c75, 0x002c82, 0x002c84, 0x002c86, 0x002c88, 0x002c8a,
        0x002c8c, 0x002c8e, 0x002c90, 0x002c92, 0x002c94, 0x002c96, 0x002c98, 0x002c9a,
        0x002c9c, 0x002c9e, 0x002ca0, 0x002ca2, 0x002ca4, 0x002ca6, 0x002ca8, 0x002caa,
        0x002cac, 0x002cae, 0x002cb0, 0x002cb2, 0x002cb4, 0x002cb6, 0x002cb8, 0x002cba,
        0x002cbc, 0x002cbe, 0x002cc0, 0x002cc2, 0x002cc4, 0x002cc6, 0x002cc8, 0x002cca,
        0x002ccc, 0x002cce, 0x002cd0, 0x002cd2, 0x002cd4, 0x002cd6, 0x002cd8, 0x002cda,
        0x002cdc, 0x002cde, 0x002ce0, 0x002ce2, 0x002ceb, 0x002ced, 0x002cf2, 0x00a640,
        0x00a642, 0x00a644, 0x00a646, 0x00a648, 0x00a64a, 0x00a64c, 0x00a64e, 0x00a650,
        0x00a652, 0x00a654, 0x00a656, 0x00a658, 0x00a65a, 0x00a65c, 0x00a65e, 0x00a660,
        0x00a662, 0x00a664, 0x00a666, 0x00a668, 0x00a66a, 0x00a66c, 0x00a680, 0x00a682,
        0x00a684, 0x00a686, 0x00a688, 0x00a68a, 0x00a68c, 0x00a68e, 0x00a690, 0x00a692,
        0x00a694, 0x00a696, 0x00a698, 0x00a69a, 0x00a722, 0x00a724, 0x00a726, 0x00a728,
        0x00a72a, 0x00a72c, 0x00a72e, 0x00a732, 0x00a734, 0x00a736, 0x00a738, 0x00a73a,
        0x00a73c, 0x00a73e, 0x00a740, 0x00a742, 0x00a744, 0x00a746, 0x00a748, 0x00a74a,
        0x00a74c, 0x00a74e, 0x00a750, 0x00a752, 0x00a754, 0x00a756, 0x00a758, 0x00a75a,
        0x00a75c, 0x00a75e, 0x00a760, 0x00a762, 0x00a764, 0x00a766, 0x00a768, 0x00a76a,
        0x00a76c, 0x00a76e, 0x00a779, 0x00a77b, 0x00a780, 0x00a782, 0x00a784, 0x00a786,
        0x00a78b, 0x00a78d, 0x00a790, 0x00a792, 0x00a796, 0x00a798, 0x00a79a, 0x00a79c,
        0x00a79e, 0x00a7a0, 0x00a7a2, 0x00a7a4, 0x00a7a6, 0x00a7a8, 0x00a7b6, 0x00a7b8,
        0x00a7ba, 0x00a7bc, 0x00a7be, 0x00a7c0, 0x00a7c2, 0x00a7c9, 0x00a7ce, 0x00a7d0,
        0x00a7d2, 0x00a7d4, 0x00a7d6, 0x00a7d8, 0x00a7da, 0x00a7dc, 0x00a7f5,
    };
    const ranges = [_][2]u21{
        .{ 0x000041, 0x00005a },
        .{ 0x0000c0, 0x0000d6 },
        .{ 0x0000d8, 0x0000de },
        .{ 0x000178, 0x000179 },
        .{ 0x000181, 0x000182 },
        .{ 0x000186, 0x000187 },
        .{ 0x000189, 0x00018b },
        .{ 0x00018e, 0x000191 },
        .{ 0x000193, 0x000194 },
        .{ 0x000196, 0x000198 },
        .{ 0x00019c, 0x00019d },
        .{ 0x00019f, 0x0001a0 },
        .{ 0x0001a6, 0x0001a7 },
        .{ 0x0001ae, 0x0001af },
        .{ 0x0001b1, 0x0001b3 },
        .{ 0x0001b7, 0x0001b8 },
        .{ 0x0001c4, 0x0001c5 },
        .{ 0x0001c7, 0x0001c8 },
        .{ 0x0001ca, 0x0001cb },
        .{ 0x0001f1, 0x0001f2 },
        .{ 0x0001f6, 0x0001f8 },
        .{ 0x00023a, 0x00023b },
        .{ 0x00023d, 0x00023e },
        .{ 0x000243, 0x000246 },
        .{ 0x000388, 0x00038a },
        .{ 0x00038e, 0x00038f },
        .{ 0x000391, 0x0003a1 },
        .{ 0x0003a3, 0x0003ab },
        .{ 0x0003f9, 0x0003fa },
        .{ 0x0003fd, 0x00042f },
        .{ 0x0004c0, 0x0004c1 },
        .{ 0x000531, 0x000556 },
        .{ 0x0010a0, 0x0010c5 },
        .{ 0x0013a0, 0x0013f5 },
        .{ 0x001c90, 0x001cba },
        .{ 0x001cbd, 0x001cbf },
        .{ 0x001f08, 0x001f0f },
        .{ 0x001f18, 0x001f1d },
        .{ 0x001f28, 0x001f2f },
        .{ 0x001f38, 0x001f3f },
        .{ 0x001f48, 0x001f4d },
        .{ 0x001f68, 0x001f6f },
        .{ 0x001f88, 0x001f8f },
        .{ 0x001f98, 0x001f9f },
        .{ 0x001fa8, 0x001faf },
        .{ 0x001fb8, 0x001fbc },
        .{ 0x001fc8, 0x001fcc },
        .{ 0x001fd8, 0x001fdb },
        .{ 0x001fe8, 0x001fec },
        .{ 0x001ff8, 0x001ffc },
        .{ 0x00212a, 0x00212b },
        .{ 0x002160, 0x00216f },
        .{ 0x0024b6, 0x0024cf },
        .{ 0x002c00, 0x002c2f },
        .{ 0x002c62, 0x002c64 },
        .{ 0x002c6d, 0x002c70 },
        .{ 0x002c7e, 0x002c80 },
        .{ 0x00a77d, 0x00a77e },
        .{ 0x00a7aa, 0x00a7ae },
        .{ 0x00a7b0, 0x00a7b4 },
        .{ 0x00a7c4, 0x00a7c7 },
        .{ 0x00a7cb, 0x00a7cc },
        .{ 0x00ff21, 0x00ff3a },
        .{ 0x010400, 0x010427 },
        .{ 0x0104b0, 0x0104d3 },
        .{ 0x010570, 0x01057a },
        .{ 0x01057c, 0x01058a },
        .{ 0x01058c, 0x010592 },
        .{ 0x010594, 0x010595 },
        .{ 0x010c80, 0x010cb2 },
        .{ 0x010d50, 0x010d65 },
        .{ 0x0118a0, 0x0118bf },
        .{ 0x016e40, 0x016e5f },
        .{ 0x016ea0, 0x016eb8 },
        .{ 0x01e900, 0x01e921 },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeChangesWhenTitlecasedCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000b5, 0x000101, 0x000103, 0x000105, 0x000107, 0x000109, 0x00010b, 0x00010d,
        0x00010f, 0x000111, 0x000113, 0x000115, 0x000117, 0x000119, 0x00011b, 0x00011d,
        0x00011f, 0x000121, 0x000123, 0x000125, 0x000127, 0x000129, 0x00012b, 0x00012d,
        0x00012f, 0x000131, 0x000133, 0x000135, 0x000137, 0x00013a, 0x00013c, 0x00013e,
        0x000140, 0x000142, 0x000144, 0x000146, 0x00014b, 0x00014d, 0x00014f, 0x000151,
        0x000153, 0x000155, 0x000157, 0x000159, 0x00015b, 0x00015d, 0x00015f, 0x000161,
        0x000163, 0x000165, 0x000167, 0x000169, 0x00016b, 0x00016d, 0x00016f, 0x000171,
        0x000173, 0x000175, 0x000177, 0x00017a, 0x00017c, 0x000183, 0x000185, 0x000188,
        0x00018c, 0x000192, 0x000195, 0x00019e, 0x0001a1, 0x0001a3, 0x0001a5, 0x0001a8,
        0x0001ad, 0x0001b0, 0x0001b4, 0x0001b6, 0x0001b9, 0x0001bd, 0x0001bf, 0x0001c4,
        0x0001cc, 0x0001ce, 0x0001d0, 0x0001d2, 0x0001d4, 0x0001d6, 0x0001d8, 0x0001da,
        0x0001df, 0x0001e1, 0x0001e3, 0x0001e5, 0x0001e7, 0x0001e9, 0x0001eb, 0x0001ed,
        0x0001f3, 0x0001f5, 0x0001f9, 0x0001fb, 0x0001fd, 0x0001ff, 0x000201, 0x000203,
        0x000205, 0x000207, 0x000209, 0x00020b, 0x00020d, 0x00020f, 0x000211, 0x000213,
        0x000215, 0x000217, 0x000219, 0x00021b, 0x00021d, 0x00021f, 0x000223, 0x000225,
        0x000227, 0x000229, 0x00022b, 0x00022d, 0x00022f, 0x000231, 0x000233, 0x00023c,
        0x000242, 0x000247, 0x000249, 0x00024b, 0x00024d, 0x000259, 0x00026f, 0x000275,
        0x00027d, 0x000280, 0x000292, 0x000345, 0x000371, 0x000373, 0x000377, 0x000390,
        0x0003d9, 0x0003db, 0x0003dd, 0x0003df, 0x0003e1, 0x0003e3, 0x0003e5, 0x0003e7,
        0x0003e9, 0x0003eb, 0x0003ed, 0x0003f5, 0x0003f8, 0x0003fb, 0x000461, 0x000463,
        0x000465, 0x000467, 0x000469, 0x00046b, 0x00046d, 0x00046f, 0x000471, 0x000473,
        0x000475, 0x000477, 0x000479, 0x00047b, 0x00047d, 0x00047f, 0x000481, 0x00048b,
        0x00048d, 0x00048f, 0x000491, 0x000493, 0x000495, 0x000497, 0x000499, 0x00049b,
        0x00049d, 0x00049f, 0x0004a1, 0x0004a3, 0x0004a5, 0x0004a7, 0x0004a9, 0x0004ab,
        0x0004ad, 0x0004af, 0x0004b1, 0x0004b3, 0x0004b5, 0x0004b7, 0x0004b9, 0x0004bb,
        0x0004bd, 0x0004bf, 0x0004c2, 0x0004c4, 0x0004c6, 0x0004c8, 0x0004ca, 0x0004cc,
        0x0004d1, 0x0004d3, 0x0004d5, 0x0004d7, 0x0004d9, 0x0004db, 0x0004dd, 0x0004df,
        0x0004e1, 0x0004e3, 0x0004e5, 0x0004e7, 0x0004e9, 0x0004eb, 0x0004ed, 0x0004ef,
        0x0004f1, 0x0004f3, 0x0004f5, 0x0004f7, 0x0004f9, 0x0004fb, 0x0004fd, 0x0004ff,
        0x000501, 0x000503, 0x000505, 0x000507, 0x000509, 0x00050b, 0x00050d, 0x00050f,
        0x000511, 0x000513, 0x000515, 0x000517, 0x000519, 0x00051b, 0x00051d, 0x00051f,
        0x000521, 0x000523, 0x000525, 0x000527, 0x000529, 0x00052b, 0x00052d, 0x00052f,
        0x001c8a, 0x001d79, 0x001d7d, 0x001d8e, 0x001e01, 0x001e03, 0x001e05, 0x001e07,
        0x001e09, 0x001e0b, 0x001e0d, 0x001e0f, 0x001e11, 0x001e13, 0x001e15, 0x001e17,
        0x001e19, 0x001e1b, 0x001e1d, 0x001e1f, 0x001e21, 0x001e23, 0x001e25, 0x001e27,
        0x001e29, 0x001e2b, 0x001e2d, 0x001e2f, 0x001e31, 0x001e33, 0x001e35, 0x001e37,
        0x001e39, 0x001e3b, 0x001e3d, 0x001e3f, 0x001e41, 0x001e43, 0x001e45, 0x001e47,
        0x001e49, 0x001e4b, 0x001e4d, 0x001e4f, 0x001e51, 0x001e53, 0x001e55, 0x001e57,
        0x001e59, 0x001e5b, 0x001e5d, 0x001e5f, 0x001e61, 0x001e63, 0x001e65, 0x001e67,
        0x001e69, 0x001e6b, 0x001e6d, 0x001e6f, 0x001e71, 0x001e73, 0x001e75, 0x001e77,
        0x001e79, 0x001e7b, 0x001e7d, 0x001e7f, 0x001e81, 0x001e83, 0x001e85, 0x001e87,
        0x001e89, 0x001e8b, 0x001e8d, 0x001e8f, 0x001e91, 0x001e93, 0x001ea1, 0x001ea3,
        0x001ea5, 0x001ea7, 0x001ea9, 0x001eab, 0x001ead, 0x001eaf, 0x001eb1, 0x001eb3,
        0x001eb5, 0x001eb7, 0x001eb9, 0x001ebb, 0x001ebd, 0x001ebf, 0x001ec1, 0x001ec3,
        0x001ec5, 0x001ec7, 0x001ec9, 0x001ecb, 0x001ecd, 0x001ecf, 0x001ed1, 0x001ed3,
        0x001ed5, 0x001ed7, 0x001ed9, 0x001edb, 0x001edd, 0x001edf, 0x001ee1, 0x001ee3,
        0x001ee5, 0x001ee7, 0x001ee9, 0x001eeb, 0x001eed, 0x001eef, 0x001ef1, 0x001ef3,
        0x001ef5, 0x001ef7, 0x001ef9, 0x001efb, 0x001efd, 0x001fbe, 0x00214e, 0x002184,
        0x002c61, 0x002c68, 0x002c6a, 0x002c6c, 0x002c73, 0x002c76, 0x002c81, 0x002c83,
        0x002c85, 0x002c87, 0x002c89, 0x002c8b, 0x002c8d, 0x002c8f, 0x002c91, 0x002c93,
        0x002c95, 0x002c97, 0x002c99, 0x002c9b, 0x002c9d, 0x002c9f, 0x002ca1, 0x002ca3,
        0x002ca5, 0x002ca7, 0x002ca9, 0x002cab, 0x002cad, 0x002caf, 0x002cb1, 0x002cb3,
        0x002cb5, 0x002cb7, 0x002cb9, 0x002cbb, 0x002cbd, 0x002cbf, 0x002cc1, 0x002cc3,
        0x002cc5, 0x002cc7, 0x002cc9, 0x002ccb, 0x002ccd, 0x002ccf, 0x002cd1, 0x002cd3,
        0x002cd5, 0x002cd7, 0x002cd9, 0x002cdb, 0x002cdd, 0x002cdf, 0x002ce1, 0x002ce3,
        0x002cec, 0x002cee, 0x002cf3, 0x002d27, 0x002d2d, 0x00a641, 0x00a643, 0x00a645,
        0x00a647, 0x00a649, 0x00a64b, 0x00a64d, 0x00a64f, 0x00a651, 0x00a653, 0x00a655,
        0x00a657, 0x00a659, 0x00a65b, 0x00a65d, 0x00a65f, 0x00a661, 0x00a663, 0x00a665,
        0x00a667, 0x00a669, 0x00a66b, 0x00a66d, 0x00a681, 0x00a683, 0x00a685, 0x00a687,
        0x00a689, 0x00a68b, 0x00a68d, 0x00a68f, 0x00a691, 0x00a693, 0x00a695, 0x00a697,
        0x00a699, 0x00a69b, 0x00a723, 0x00a725, 0x00a727, 0x00a729, 0x00a72b, 0x00a72d,
        0x00a72f, 0x00a733, 0x00a735, 0x00a737, 0x00a739, 0x00a73b, 0x00a73d, 0x00a73f,
        0x00a741, 0x00a743, 0x00a745, 0x00a747, 0x00a749, 0x00a74b, 0x00a74d, 0x00a74f,
        0x00a751, 0x00a753, 0x00a755, 0x00a757, 0x00a759, 0x00a75b, 0x00a75d, 0x00a75f,
        0x00a761, 0x00a763, 0x00a765, 0x00a767, 0x00a769, 0x00a76b, 0x00a76d, 0x00a76f,
        0x00a77a, 0x00a77c, 0x00a77f, 0x00a781, 0x00a783, 0x00a785, 0x00a787, 0x00a78c,
        0x00a791, 0x00a797, 0x00a799, 0x00a79b, 0x00a79d, 0x00a79f, 0x00a7a1, 0x00a7a3,
        0x00a7a5, 0x00a7a7, 0x00a7a9, 0x00a7b5, 0x00a7b7, 0x00a7b9, 0x00a7bb, 0x00a7bd,
        0x00a7bf, 0x00a7c1, 0x00a7c3, 0x00a7c8, 0x00a7ca, 0x00a7cd, 0x00a7cf, 0x00a7d1,
        0x00a7d3, 0x00a7d5, 0x00a7d7, 0x00a7d9, 0x00a7db, 0x00a7f6, 0x00ab53,
    };
    const ranges = [_][2]u21{
        .{ 0x000061, 0x00007a },
        .{ 0x0000df, 0x0000f6 },
        .{ 0x0000f8, 0x0000ff },
        .{ 0x000148, 0x000149 },
        .{ 0x00017e, 0x000180 },
        .{ 0x000199, 0x00019b },
        .{ 0x0001c6, 0x0001c7 },
        .{ 0x0001c9, 0x0001ca },
        .{ 0x0001dc, 0x0001dd },
        .{ 0x0001ef, 0x0001f1 },
        .{ 0x00023f, 0x000240 },
        .{ 0x00024f, 0x000254 },
        .{ 0x000256, 0x000257 },
        .{ 0x00025b, 0x00025c },
        .{ 0x000260, 0x000261 },
        .{ 0x000263, 0x000266 },
        .{ 0x000268, 0x00026c },
        .{ 0x000271, 0x000272 },
        .{ 0x000282, 0x000283 },
        .{ 0x000287, 0x00028c },
        .{ 0x00029d, 0x00029e },
        .{ 0x00037b, 0x00037d },
        .{ 0x0003ac, 0x0003ce },
        .{ 0x0003d0, 0x0003d1 },
        .{ 0x0003d5, 0x0003d7 },
        .{ 0x0003ef, 0x0003f3 },
        .{ 0x000430, 0x00045f },
        .{ 0x0004ce, 0x0004cf },
        .{ 0x000561, 0x000587 },
        .{ 0x0013f8, 0x0013fd },
        .{ 0x001c80, 0x001c88 },
        .{ 0x001e95, 0x001e9b },
        .{ 0x001eff, 0x001f07 },
        .{ 0x001f10, 0x001f15 },
        .{ 0x001f20, 0x001f27 },
        .{ 0x001f30, 0x001f37 },
        .{ 0x001f40, 0x001f45 },
        .{ 0x001f50, 0x001f57 },
        .{ 0x001f60, 0x001f67 },
        .{ 0x001f70, 0x001f7d },
        .{ 0x001f80, 0x001f87 },
        .{ 0x001f90, 0x001f97 },
        .{ 0x001fa0, 0x001fa7 },
        .{ 0x001fb0, 0x001fb4 },
        .{ 0x001fb6, 0x001fb7 },
        .{ 0x001fc2, 0x001fc4 },
        .{ 0x001fc6, 0x001fc7 },
        .{ 0x001fd0, 0x001fd3 },
        .{ 0x001fd6, 0x001fd7 },
        .{ 0x001fe0, 0x001fe7 },
        .{ 0x001ff2, 0x001ff4 },
        .{ 0x001ff6, 0x001ff7 },
        .{ 0x002170, 0x00217f },
        .{ 0x0024d0, 0x0024e9 },
        .{ 0x002c30, 0x002c5f },
        .{ 0x002c65, 0x002c66 },
        .{ 0x002d00, 0x002d25 },
        .{ 0x00a793, 0x00a794 },
        .{ 0x00ab70, 0x00abbf },
        .{ 0x00fb00, 0x00fb06 },
        .{ 0x00fb13, 0x00fb17 },
        .{ 0x00ff41, 0x00ff5a },
        .{ 0x010428, 0x01044f },
        .{ 0x0104d8, 0x0104fb },
        .{ 0x010597, 0x0105a1 },
        .{ 0x0105a3, 0x0105b1 },
        .{ 0x0105b3, 0x0105b9 },
        .{ 0x0105bb, 0x0105bc },
        .{ 0x010cc0, 0x010cf2 },
        .{ 0x010d70, 0x010d85 },
        .{ 0x0118c0, 0x0118df },
        .{ 0x016e60, 0x016e7f },
        .{ 0x016ebb, 0x016ed3 },
        .{ 0x01e922, 0x01e943 },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeChangesWhenUppercasedCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000b5, 0x000101, 0x000103, 0x000105, 0x000107, 0x000109, 0x00010b, 0x00010d,
        0x00010f, 0x000111, 0x000113, 0x000115, 0x000117, 0x000119, 0x00011b, 0x00011d,
        0x00011f, 0x000121, 0x000123, 0x000125, 0x000127, 0x000129, 0x00012b, 0x00012d,
        0x00012f, 0x000131, 0x000133, 0x000135, 0x000137, 0x00013a, 0x00013c, 0x00013e,
        0x000140, 0x000142, 0x000144, 0x000146, 0x00014b, 0x00014d, 0x00014f, 0x000151,
        0x000153, 0x000155, 0x000157, 0x000159, 0x00015b, 0x00015d, 0x00015f, 0x000161,
        0x000163, 0x000165, 0x000167, 0x000169, 0x00016b, 0x00016d, 0x00016f, 0x000171,
        0x000173, 0x000175, 0x000177, 0x00017a, 0x00017c, 0x000183, 0x000185, 0x000188,
        0x00018c, 0x000192, 0x000195, 0x00019e, 0x0001a1, 0x0001a3, 0x0001a5, 0x0001a8,
        0x0001ad, 0x0001b0, 0x0001b4, 0x0001b6, 0x0001b9, 0x0001bd, 0x0001bf, 0x0001ce,
        0x0001d0, 0x0001d2, 0x0001d4, 0x0001d6, 0x0001d8, 0x0001da, 0x0001df, 0x0001e1,
        0x0001e3, 0x0001e5, 0x0001e7, 0x0001e9, 0x0001eb, 0x0001ed, 0x0001f5, 0x0001f9,
        0x0001fb, 0x0001fd, 0x0001ff, 0x000201, 0x000203, 0x000205, 0x000207, 0x000209,
        0x00020b, 0x00020d, 0x00020f, 0x000211, 0x000213, 0x000215, 0x000217, 0x000219,
        0x00021b, 0x00021d, 0x00021f, 0x000223, 0x000225, 0x000227, 0x000229, 0x00022b,
        0x00022d, 0x00022f, 0x000231, 0x000233, 0x00023c, 0x000242, 0x000247, 0x000249,
        0x00024b, 0x00024d, 0x000259, 0x00026f, 0x000275, 0x00027d, 0x000280, 0x000292,
        0x000345, 0x000371, 0x000373, 0x000377, 0x000390, 0x0003d9, 0x0003db, 0x0003dd,
        0x0003df, 0x0003e1, 0x0003e3, 0x0003e5, 0x0003e7, 0x0003e9, 0x0003eb, 0x0003ed,
        0x0003f5, 0x0003f8, 0x0003fb, 0x000461, 0x000463, 0x000465, 0x000467, 0x000469,
        0x00046b, 0x00046d, 0x00046f, 0x000471, 0x000473, 0x000475, 0x000477, 0x000479,
        0x00047b, 0x00047d, 0x00047f, 0x000481, 0x00048b, 0x00048d, 0x00048f, 0x000491,
        0x000493, 0x000495, 0x000497, 0x000499, 0x00049b, 0x00049d, 0x00049f, 0x0004a1,
        0x0004a3, 0x0004a5, 0x0004a7, 0x0004a9, 0x0004ab, 0x0004ad, 0x0004af, 0x0004b1,
        0x0004b3, 0x0004b5, 0x0004b7, 0x0004b9, 0x0004bb, 0x0004bd, 0x0004bf, 0x0004c2,
        0x0004c4, 0x0004c6, 0x0004c8, 0x0004ca, 0x0004cc, 0x0004d1, 0x0004d3, 0x0004d5,
        0x0004d7, 0x0004d9, 0x0004db, 0x0004dd, 0x0004df, 0x0004e1, 0x0004e3, 0x0004e5,
        0x0004e7, 0x0004e9, 0x0004eb, 0x0004ed, 0x0004ef, 0x0004f1, 0x0004f3, 0x0004f5,
        0x0004f7, 0x0004f9, 0x0004fb, 0x0004fd, 0x0004ff, 0x000501, 0x000503, 0x000505,
        0x000507, 0x000509, 0x00050b, 0x00050d, 0x00050f, 0x000511, 0x000513, 0x000515,
        0x000517, 0x000519, 0x00051b, 0x00051d, 0x00051f, 0x000521, 0x000523, 0x000525,
        0x000527, 0x000529, 0x00052b, 0x00052d, 0x00052f, 0x001c8a, 0x001d79, 0x001d7d,
        0x001d8e, 0x001e01, 0x001e03, 0x001e05, 0x001e07, 0x001e09, 0x001e0b, 0x001e0d,
        0x001e0f, 0x001e11, 0x001e13, 0x001e15, 0x001e17, 0x001e19, 0x001e1b, 0x001e1d,
        0x001e1f, 0x001e21, 0x001e23, 0x001e25, 0x001e27, 0x001e29, 0x001e2b, 0x001e2d,
        0x001e2f, 0x001e31, 0x001e33, 0x001e35, 0x001e37, 0x001e39, 0x001e3b, 0x001e3d,
        0x001e3f, 0x001e41, 0x001e43, 0x001e45, 0x001e47, 0x001e49, 0x001e4b, 0x001e4d,
        0x001e4f, 0x001e51, 0x001e53, 0x001e55, 0x001e57, 0x001e59, 0x001e5b, 0x001e5d,
        0x001e5f, 0x001e61, 0x001e63, 0x001e65, 0x001e67, 0x001e69, 0x001e6b, 0x001e6d,
        0x001e6f, 0x001e71, 0x001e73, 0x001e75, 0x001e77, 0x001e79, 0x001e7b, 0x001e7d,
        0x001e7f, 0x001e81, 0x001e83, 0x001e85, 0x001e87, 0x001e89, 0x001e8b, 0x001e8d,
        0x001e8f, 0x001e91, 0x001e93, 0x001ea1, 0x001ea3, 0x001ea5, 0x001ea7, 0x001ea9,
        0x001eab, 0x001ead, 0x001eaf, 0x001eb1, 0x001eb3, 0x001eb5, 0x001eb7, 0x001eb9,
        0x001ebb, 0x001ebd, 0x001ebf, 0x001ec1, 0x001ec3, 0x001ec5, 0x001ec7, 0x001ec9,
        0x001ecb, 0x001ecd, 0x001ecf, 0x001ed1, 0x001ed3, 0x001ed5, 0x001ed7, 0x001ed9,
        0x001edb, 0x001edd, 0x001edf, 0x001ee1, 0x001ee3, 0x001ee5, 0x001ee7, 0x001ee9,
        0x001eeb, 0x001eed, 0x001eef, 0x001ef1, 0x001ef3, 0x001ef5, 0x001ef7, 0x001ef9,
        0x001efb, 0x001efd, 0x001fbc, 0x001fbe, 0x001fcc, 0x001ffc, 0x00214e, 0x002184,
        0x002c61, 0x002c68, 0x002c6a, 0x002c6c, 0x002c73, 0x002c76, 0x002c81, 0x002c83,
        0x002c85, 0x002c87, 0x002c89, 0x002c8b, 0x002c8d, 0x002c8f, 0x002c91, 0x002c93,
        0x002c95, 0x002c97, 0x002c99, 0x002c9b, 0x002c9d, 0x002c9f, 0x002ca1, 0x002ca3,
        0x002ca5, 0x002ca7, 0x002ca9, 0x002cab, 0x002cad, 0x002caf, 0x002cb1, 0x002cb3,
        0x002cb5, 0x002cb7, 0x002cb9, 0x002cbb, 0x002cbd, 0x002cbf, 0x002cc1, 0x002cc3,
        0x002cc5, 0x002cc7, 0x002cc9, 0x002ccb, 0x002ccd, 0x002ccf, 0x002cd1, 0x002cd3,
        0x002cd5, 0x002cd7, 0x002cd9, 0x002cdb, 0x002cdd, 0x002cdf, 0x002ce1, 0x002ce3,
        0x002cec, 0x002cee, 0x002cf3, 0x002d27, 0x002d2d, 0x00a641, 0x00a643, 0x00a645,
        0x00a647, 0x00a649, 0x00a64b, 0x00a64d, 0x00a64f, 0x00a651, 0x00a653, 0x00a655,
        0x00a657, 0x00a659, 0x00a65b, 0x00a65d, 0x00a65f, 0x00a661, 0x00a663, 0x00a665,
        0x00a667, 0x00a669, 0x00a66b, 0x00a66d, 0x00a681, 0x00a683, 0x00a685, 0x00a687,
        0x00a689, 0x00a68b, 0x00a68d, 0x00a68f, 0x00a691, 0x00a693, 0x00a695, 0x00a697,
        0x00a699, 0x00a69b, 0x00a723, 0x00a725, 0x00a727, 0x00a729, 0x00a72b, 0x00a72d,
        0x00a72f, 0x00a733, 0x00a735, 0x00a737, 0x00a739, 0x00a73b, 0x00a73d, 0x00a73f,
        0x00a741, 0x00a743, 0x00a745, 0x00a747, 0x00a749, 0x00a74b, 0x00a74d, 0x00a74f,
        0x00a751, 0x00a753, 0x00a755, 0x00a757, 0x00a759, 0x00a75b, 0x00a75d, 0x00a75f,
        0x00a761, 0x00a763, 0x00a765, 0x00a767, 0x00a769, 0x00a76b, 0x00a76d, 0x00a76f,
        0x00a77a, 0x00a77c, 0x00a77f, 0x00a781, 0x00a783, 0x00a785, 0x00a787, 0x00a78c,
        0x00a791, 0x00a797, 0x00a799, 0x00a79b, 0x00a79d, 0x00a79f, 0x00a7a1, 0x00a7a3,
        0x00a7a5, 0x00a7a7, 0x00a7a9, 0x00a7b5, 0x00a7b7, 0x00a7b9, 0x00a7bb, 0x00a7bd,
        0x00a7bf, 0x00a7c1, 0x00a7c3, 0x00a7c8, 0x00a7ca, 0x00a7cd, 0x00a7cf, 0x00a7d1,
        0x00a7d3, 0x00a7d5, 0x00a7d7, 0x00a7d9, 0x00a7db, 0x00a7f6, 0x00ab53,
    };
    const ranges = [_][2]u21{
        .{ 0x000061, 0x00007a },
        .{ 0x0000df, 0x0000f6 },
        .{ 0x0000f8, 0x0000ff },
        .{ 0x000148, 0x000149 },
        .{ 0x00017e, 0x000180 },
        .{ 0x000199, 0x00019b },
        .{ 0x0001c5, 0x0001c6 },
        .{ 0x0001c8, 0x0001c9 },
        .{ 0x0001cb, 0x0001cc },
        .{ 0x0001dc, 0x0001dd },
        .{ 0x0001ef, 0x0001f0 },
        .{ 0x0001f2, 0x0001f3 },
        .{ 0x00023f, 0x000240 },
        .{ 0x00024f, 0x000254 },
        .{ 0x000256, 0x000257 },
        .{ 0x00025b, 0x00025c },
        .{ 0x000260, 0x000261 },
        .{ 0x000263, 0x000266 },
        .{ 0x000268, 0x00026c },
        .{ 0x000271, 0x000272 },
        .{ 0x000282, 0x000283 },
        .{ 0x000287, 0x00028c },
        .{ 0x00029d, 0x00029e },
        .{ 0x00037b, 0x00037d },
        .{ 0x0003ac, 0x0003ce },
        .{ 0x0003d0, 0x0003d1 },
        .{ 0x0003d5, 0x0003d7 },
        .{ 0x0003ef, 0x0003f3 },
        .{ 0x000430, 0x00045f },
        .{ 0x0004ce, 0x0004cf },
        .{ 0x000561, 0x000587 },
        .{ 0x0010d0, 0x0010fa },
        .{ 0x0010fd, 0x0010ff },
        .{ 0x0013f8, 0x0013fd },
        .{ 0x001c80, 0x001c88 },
        .{ 0x001e95, 0x001e9b },
        .{ 0x001eff, 0x001f07 },
        .{ 0x001f10, 0x001f15 },
        .{ 0x001f20, 0x001f27 },
        .{ 0x001f30, 0x001f37 },
        .{ 0x001f40, 0x001f45 },
        .{ 0x001f50, 0x001f57 },
        .{ 0x001f60, 0x001f67 },
        .{ 0x001f70, 0x001f7d },
        .{ 0x001f80, 0x001fb4 },
        .{ 0x001fb6, 0x001fb7 },
        .{ 0x001fc2, 0x001fc4 },
        .{ 0x001fc6, 0x001fc7 },
        .{ 0x001fd0, 0x001fd3 },
        .{ 0x001fd6, 0x001fd7 },
        .{ 0x001fe0, 0x001fe7 },
        .{ 0x001ff2, 0x001ff4 },
        .{ 0x001ff6, 0x001ff7 },
        .{ 0x002170, 0x00217f },
        .{ 0x0024d0, 0x0024e9 },
        .{ 0x002c30, 0x002c5f },
        .{ 0x002c65, 0x002c66 },
        .{ 0x002d00, 0x002d25 },
        .{ 0x00a793, 0x00a794 },
        .{ 0x00ab70, 0x00abbf },
        .{ 0x00fb00, 0x00fb06 },
        .{ 0x00fb13, 0x00fb17 },
        .{ 0x00ff41, 0x00ff5a },
        .{ 0x010428, 0x01044f },
        .{ 0x0104d8, 0x0104fb },
        .{ 0x010597, 0x0105a1 },
        .{ 0x0105a3, 0x0105b1 },
        .{ 0x0105b3, 0x0105b9 },
        .{ 0x0105bb, 0x0105bc },
        .{ 0x010cc0, 0x010cf2 },
        .{ 0x010d70, 0x010d85 },
        .{ 0x0118c0, 0x0118df },
        .{ 0x016e60, 0x016e7f },
        .{ 0x016ebb, 0x016ed3 },
        .{ 0x01e922, 0x01e943 },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeChangesWhenNfkcCasefoldedCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0000a0, 0x0000a8, 0x0000aa, 0x0000ad, 0x0000af, 0x000100, 0x000102, 0x000104,
        0x000106, 0x000108, 0x00010a, 0x00010c, 0x00010e, 0x000110, 0x000112, 0x000114,
        0x000116, 0x000118, 0x00011a, 0x00011c, 0x00011e, 0x000120, 0x000122, 0x000124,
        0x000126, 0x000128, 0x00012a, 0x00012c, 0x00012e, 0x000130, 0x000136, 0x000139,
        0x00013b, 0x00013d, 0x000143, 0x000145, 0x000147, 0x00014c, 0x00014e, 0x000150,
        0x000152, 0x000154, 0x000156, 0x000158, 0x00015a, 0x00015c, 0x00015e, 0x000160,
        0x000162, 0x000164, 0x000166, 0x000168, 0x00016a, 0x00016c, 0x00016e, 0x000170,
        0x000172, 0x000174, 0x000176, 0x00017b, 0x00017d, 0x00017f, 0x000184, 0x0001a2,
        0x0001a4, 0x0001a9, 0x0001ac, 0x0001b5, 0x0001bc, 0x0001cf, 0x0001d1, 0x0001d3,
        0x0001d5, 0x0001d7, 0x0001d9, 0x0001db, 0x0001de, 0x0001e0, 0x0001e2, 0x0001e4,
        0x0001e6, 0x0001e8, 0x0001ea, 0x0001ec, 0x0001ee, 0x0001fa, 0x0001fc, 0x0001fe,
        0x000200, 0x000202, 0x000204, 0x000206, 0x000208, 0x00020a, 0x00020c, 0x00020e,
        0x000210, 0x000212, 0x000214, 0x000216, 0x000218, 0x00021a, 0x00021c, 0x00021e,
        0x000220, 0x000222, 0x000224, 0x000226, 0x000228, 0x00022a, 0x00022c, 0x00022e,
        0x000230, 0x000232, 0x000241, 0x000248, 0x00024a, 0x00024c, 0x00024e, 0x00034f,
        0x000370, 0x000372, 0x000374, 0x000376, 0x00037a, 0x00038c, 0x0003c2, 0x0003d8,
        0x0003da, 0x0003dc, 0x0003de, 0x0003e0, 0x0003e2, 0x0003e4, 0x0003e6, 0x0003e8,
        0x0003ea, 0x0003ec, 0x0003ee, 0x0003f7, 0x000460, 0x000462, 0x000464, 0x000466,
        0x000468, 0x00046a, 0x00046c, 0x00046e, 0x000470, 0x000472, 0x000474, 0x000476,
        0x000478, 0x00047a, 0x00047c, 0x00047e, 0x000480, 0x00048a, 0x00048c, 0x00048e,
        0x000490, 0x000492, 0x000494, 0x000496, 0x000498, 0x00049a, 0x00049c, 0x00049e,
        0x0004a0, 0x0004a2, 0x0004a4, 0x0004a6, 0x0004a8, 0x0004aa, 0x0004ac, 0x0004ae,
        0x0004b0, 0x0004b2, 0x0004b4, 0x0004b6, 0x0004b8, 0x0004ba, 0x0004bc, 0x0004be,
        0x0004c3, 0x0004c5, 0x0004c7, 0x0004c9, 0x0004cb, 0x0004cd, 0x0004d0, 0x0004d2,
        0x0004d4, 0x0004d6, 0x0004d8, 0x0004da, 0x0004dc, 0x0004de, 0x0004e0, 0x0004e2,
        0x0004e4, 0x0004e6, 0x0004e8, 0x0004ea, 0x0004ec, 0x0004ee, 0x0004f0, 0x0004f2,
        0x0004f4, 0x0004f6, 0x0004f8, 0x0004fa, 0x0004fc, 0x0004fe, 0x000500, 0x000502,
        0x000504, 0x000506, 0x000508, 0x00050a, 0x00050c, 0x00050e, 0x000510, 0x000512,
        0x000514, 0x000516, 0x000518, 0x00051a, 0x00051c, 0x00051e, 0x000520, 0x000522,
        0x000524, 0x000526, 0x000528, 0x00052a, 0x00052c, 0x00052e, 0x000587, 0x00061c,
        0x0009df, 0x000a33, 0x000a36, 0x000a5e, 0x000e33, 0x000eb3, 0x000f0c, 0x000f43,
        0x000f4d, 0x000f52, 0x000f57, 0x000f5c, 0x000f69, 0x000f73, 0x000f81, 0x000f93,
        0x000f9d, 0x000fa2, 0x000fa7, 0x000fac, 0x000fb9, 0x0010c7, 0x0010cd, 0x0010fc,
        0x001d78, 0x001e00, 0x001e02, 0x001e04, 0x001e06, 0x001e08, 0x001e0a, 0x001e0c,
        0x001e0e, 0x001e10, 0x001e12, 0x001e14, 0x001e16, 0x001e18, 0x001e1a, 0x001e1c,
        0x001e1e, 0x001e20, 0x001e22, 0x001e24, 0x001e26, 0x001e28, 0x001e2a, 0x001e2c,
        0x001e2e, 0x001e30, 0x001e32, 0x001e34, 0x001e36, 0x001e38, 0x001e3a, 0x001e3c,
        0x001e3e, 0x001e40, 0x001e42, 0x001e44, 0x001e46, 0x001e48, 0x001e4a, 0x001e4c,
        0x001e4e, 0x001e50, 0x001e52, 0x001e54, 0x001e56, 0x001e58, 0x001e5a, 0x001e5c,
        0x001e5e, 0x001e60, 0x001e62, 0x001e64, 0x001e66, 0x001e68, 0x001e6a, 0x001e6c,
        0x001e6e, 0x001e70, 0x001e72, 0x001e74, 0x001e76, 0x001e78, 0x001e7a, 0x001e7c,
        0x001e7e, 0x001e80, 0x001e82, 0x001e84, 0x001e86, 0x001e88, 0x001e8a, 0x001e8c,
        0x001e8e, 0x001e90, 0x001e92, 0x001e94, 0x001e9e, 0x001ea0, 0x001ea2, 0x001ea4,
        0x001ea6, 0x001ea8, 0x001eaa, 0x001eac, 0x001eae, 0x001eb0, 0x001eb2, 0x001eb4,
        0x001eb6, 0x001eb8, 0x001eba, 0x001ebc, 0x001ebe, 0x001ec0, 0x001ec2, 0x001ec4,
        0x001ec6, 0x001ec8, 0x001eca, 0x001ecc, 0x001ece, 0x001ed0, 0x001ed2, 0x001ed4,
        0x001ed6, 0x001ed8, 0x001eda, 0x001edc, 0x001ede, 0x001ee0, 0x001ee2, 0x001ee4,
        0x001ee6, 0x001ee8, 0x001eea, 0x001eec, 0x001eee, 0x001ef0, 0x001ef2, 0x001ef4,
        0x001ef6, 0x001ef8, 0x001efa, 0x001efc, 0x001efe, 0x001f59, 0x001f5b, 0x001f5d,
        0x001f5f, 0x001f71, 0x001f73, 0x001f75, 0x001f77, 0x001f79, 0x001f7b, 0x001f7d,
        0x001fd3, 0x001fe3, 0x002011, 0x002017, 0x00203c, 0x00203e, 0x002057, 0x0020a8,
        0x002124, 0x002126, 0x002128, 0x002183, 0x002189, 0x002a0c, 0x002adc, 0x002c60,
        0x002c67, 0x002c69, 0x002c6b, 0x002c72, 0x002c75, 0x002c82, 0x002c84, 0x002c86,
        0x002c88, 0x002c8a, 0x002c8c, 0x002c8e, 0x002c90, 0x002c92, 0x002c94, 0x002c96,
        0x002c98, 0x002c9a, 0x002c9c, 0x002c9e, 0x002ca0, 0x002ca2, 0x002ca4, 0x002ca6,
        0x002ca8, 0x002caa, 0x002cac, 0x002cae, 0x002cb0, 0x002cb2, 0x002cb4, 0x002cb6,
        0x002cb8, 0x002cba, 0x002cbc, 0x002cbe, 0x002cc0, 0x002cc2, 0x002cc4, 0x002cc6,
        0x002cc8, 0x002cca, 0x002ccc, 0x002cce, 0x002cd0, 0x002cd2, 0x002cd4, 0x002cd6,
        0x002cd8, 0x002cda, 0x002cdc, 0x002cde, 0x002ce0, 0x002ce2, 0x002ceb, 0x002ced,
        0x002cf2, 0x002d6f, 0x002e9f, 0x002ef3, 0x003000, 0x003036, 0x00309f, 0x0030ff,
        0x00a640, 0x00a642, 0x00a644, 0x00a646, 0x00a648, 0x00a64a, 0x00a64c, 0x00a64e,
        0x00a650, 0x00a652, 0x00a654, 0x00a656, 0x00a658, 0x00a65a, 0x00a65c, 0x00a65e,
        0x00a660, 0x00a662, 0x00a664, 0x00a666, 0x00a668, 0x00a66a, 0x00a66c, 0x00a680,
        0x00a682, 0x00a684, 0x00a686, 0x00a688, 0x00a68a, 0x00a68c, 0x00a68e, 0x00a690,
        0x00a692, 0x00a694, 0x00a696, 0x00a698, 0x00a69a, 0x00a722, 0x00a724, 0x00a726,
        0x00a728, 0x00a72a, 0x00a72c, 0x00a72e, 0x00a732, 0x00a734, 0x00a736, 0x00a738,
        0x00a73a, 0x00a73c, 0x00a73e, 0x00a740, 0x00a742, 0x00a744, 0x00a746, 0x00a748,
        0x00a74a, 0x00a74c, 0x00a74e, 0x00a750, 0x00a752, 0x00a754, 0x00a756, 0x00a758,
        0x00a75a, 0x00a75c, 0x00a75e, 0x00a760, 0x00a762, 0x00a764, 0x00a766, 0x00a768,
        0x00a76a, 0x00a76c, 0x00a76e, 0x00a770, 0x00a779, 0x00a77b, 0x00a780, 0x00a782,
        0x00a784, 0x00a786, 0x00a78b, 0x00a78d, 0x00a790, 0x00a792, 0x00a796, 0x00a798,
        0x00a79a, 0x00a79c, 0x00a79e, 0x00a7a0, 0x00a7a2, 0x00a7a4, 0x00a7a6, 0x00a7a8,
        0x00a7b6, 0x00a7b8, 0x00a7ba, 0x00a7bc, 0x00a7be, 0x00a7c0, 0x00a7c2, 0x00a7c9,
        0x00a7ce, 0x00a7d0, 0x00a7d2, 0x00a7d4, 0x00a7d6, 0x00a7d8, 0x00a7da, 0x00a7dc,
        0x00ab69, 0x00fa10, 0x00fa12, 0x00fa20, 0x00fa22, 0x00fb1d, 0x00fb3e, 0x00fe74,
        0x00feff, 0x01d4a2, 0x01d4bb, 0x01d546, 0x01ee24, 0x01ee27, 0x01ee39, 0x01ee3b,
        0x01ee42, 0x01ee47, 0x01ee49, 0x01ee4b, 0x01ee54, 0x01ee57, 0x01ee59, 0x01ee5b,
        0x01ee5d, 0x01ee5f, 0x01ee64, 0x01ee7e, 0x01f190,
    };
    const ranges = [_][2]u21{
        .{ 0x000041, 0x00005a },
        .{ 0x0000b2, 0x0000b5 },
        .{ 0x0000b8, 0x0000ba },
        .{ 0x0000bc, 0x0000be },
        .{ 0x0000c0, 0x0000d6 },
        .{ 0x0000d8, 0x0000df },
        .{ 0x000132, 0x000134 },
        .{ 0x00013f, 0x000141 },
        .{ 0x000149, 0x00014a },
        .{ 0x000178, 0x000179 },
        .{ 0x000181, 0x000182 },
        .{ 0x000186, 0x000187 },
        .{ 0x000189, 0x00018b },
        .{ 0x00018e, 0x000191 },
        .{ 0x000193, 0x000194 },
        .{ 0x000196, 0x000198 },
        .{ 0x00019c, 0x00019d },
        .{ 0x00019f, 0x0001a0 },
        .{ 0x0001a6, 0x0001a7 },
        .{ 0x0001ae, 0x0001af },
        .{ 0x0001b1, 0x0001b3 },
        .{ 0x0001b7, 0x0001b8 },
        .{ 0x0001c4, 0x0001cd },
        .{ 0x0001f1, 0x0001f4 },
        .{ 0x0001f6, 0x0001f8 },
        .{ 0x00023a, 0x00023b },
        .{ 0x00023d, 0x00023e },
        .{ 0x000243, 0x000246 },
        .{ 0x0002b0, 0x0002b8 },
        .{ 0x0002d8, 0x0002dd },
        .{ 0x0002e0, 0x0002e4 },
        .{ 0x000340, 0x000341 },
        .{ 0x000343, 0x000345 },
        .{ 0x00037e, 0x00037f },
        .{ 0x000384, 0x00038a },
        .{ 0x00038e, 0x00038f },
        .{ 0x000391, 0x0003a1 },
        .{ 0x0003a3, 0x0003ab },
        .{ 0x0003cf, 0x0003d6 },
        .{ 0x0003f0, 0x0003f2 },
        .{ 0x0003f4, 0x0003f5 },
        .{ 0x0003f9, 0x0003fa },
        .{ 0x0003fd, 0x00042f },
        .{ 0x0004c0, 0x0004c1 },
        .{ 0x000531, 0x000556 },
        .{ 0x000675, 0x000678 },
        .{ 0x000958, 0x00095f },
        .{ 0x0009dc, 0x0009dd },
        .{ 0x000a59, 0x000a5b },
        .{ 0x000b5c, 0x000b5d },
        .{ 0x000edc, 0x000edd },
        .{ 0x000f75, 0x000f79 },
        .{ 0x0010a0, 0x0010c5 },
        .{ 0x00115f, 0x001160 },
        .{ 0x0013f8, 0x0013fd },
        .{ 0x0017b4, 0x0017b5 },
        .{ 0x00180b, 0x00180f },
        .{ 0x001c80, 0x001c89 },
        .{ 0x001c90, 0x001cba },
        .{ 0x001cbd, 0x001cbf },
        .{ 0x001d2c, 0x001d2e },
        .{ 0x001d30, 0x001d3a },
        .{ 0x001d3c, 0x001d4d },
        .{ 0x001d4f, 0x001d6a },
        .{ 0x001d9b, 0x001dbf },
        .{ 0x001e9a, 0x001e9b },
        .{ 0x001f08, 0x001f0f },
        .{ 0x001f18, 0x001f1d },
        .{ 0x001f28, 0x001f2f },
        .{ 0x001f38, 0x001f3f },
        .{ 0x001f48, 0x001f4d },
        .{ 0x001f68, 0x001f6f },
        .{ 0x001f80, 0x001faf },
        .{ 0x001fb2, 0x001fb4 },
        .{ 0x001fb7, 0x001fc4 },
        .{ 0x001fc7, 0x001fcf },
        .{ 0x001fd8, 0x001fdb },
        .{ 0x001fdd, 0x001fdf },
        .{ 0x001fe8, 0x001fef },
        .{ 0x001ff2, 0x001ff4 },
        .{ 0x001ff7, 0x001ffe },
        .{ 0x002000, 0x00200f },
        .{ 0x002024, 0x002026 },
        .{ 0x00202a, 0x00202f },
        .{ 0x002033, 0x002034 },
        .{ 0x002036, 0x002037 },
        .{ 0x002047, 0x002049 },
        .{ 0x00205f, 0x002071 },
        .{ 0x002074, 0x00208e },
        .{ 0x002090, 0x00209c },
        .{ 0x002100, 0x002103 },
        .{ 0x002105, 0x002107 },
        .{ 0x002109, 0x002113 },
        .{ 0x002115, 0x002116 },
        .{ 0x002119, 0x00211d },
        .{ 0x002120, 0x002122 },
        .{ 0x00212a, 0x00212d },
        .{ 0x00212f, 0x002139 },
        .{ 0x00213b, 0x002140 },
        .{ 0x002145, 0x002149 },
        .{ 0x002150, 0x00217f },
        .{ 0x00222c, 0x00222d },
        .{ 0x00222f, 0x002230 },
        .{ 0x002329, 0x00232a },
        .{ 0x002460, 0x0024ea },
        .{ 0x002a74, 0x002a76 },
        .{ 0x002c00, 0x002c2f },
        .{ 0x002c62, 0x002c64 },
        .{ 0x002c6d, 0x002c70 },
        .{ 0x002c7c, 0x002c80 },
        .{ 0x002f00, 0x002fd5 },
        .{ 0x003038, 0x00303a },
        .{ 0x00309b, 0x00309c },
        .{ 0x003131, 0x00318e },
        .{ 0x003192, 0x00319f },
        .{ 0x003200, 0x00321e },
        .{ 0x003220, 0x003247 },
        .{ 0x003250, 0x00327e },
        .{ 0x003280, 0x0033ff },
        .{ 0x00a69c, 0x00a69d },
        .{ 0x00a77d, 0x00a77e },
        .{ 0x00a7aa, 0x00a7ae },
        .{ 0x00a7b0, 0x00a7b4 },
        .{ 0x00a7c4, 0x00a7c7 },
        .{ 0x00a7cb, 0x00a7cc },
        .{ 0x00a7f1, 0x00a7f5 },
        .{ 0x00a7f8, 0x00a7f9 },
        .{ 0x00ab5c, 0x00ab5f },
        .{ 0x00ab70, 0x00abbf },
        .{ 0x00f900, 0x00fa0d },
        .{ 0x00fa15, 0x00fa1e },
        .{ 0x00fa25, 0x00fa26 },
        .{ 0x00fa2a, 0x00fa6d },
        .{ 0x00fa70, 0x00fad9 },
        .{ 0x00fb00, 0x00fb06 },
        .{ 0x00fb13, 0x00fb17 },
        .{ 0x00fb1f, 0x00fb36 },
        .{ 0x00fb38, 0x00fb3c },
        .{ 0x00fb40, 0x00fb41 },
        .{ 0x00fb43, 0x00fb44 },
        .{ 0x00fb46, 0x00fbb1 },
        .{ 0x00fbd3, 0x00fd3d },
        .{ 0x00fd50, 0x00fd8f },
        .{ 0x00fd92, 0x00fdc7 },
        .{ 0x00fdf0, 0x00fdfc },
        .{ 0x00fe00, 0x00fe19 },
        .{ 0x00fe30, 0x00fe44 },
        .{ 0x00fe47, 0x00fe52 },
        .{ 0x00fe54, 0x00fe66 },
        .{ 0x00fe68, 0x00fe6b },
        .{ 0x00fe70, 0x00fe72 },
        .{ 0x00fe76, 0x00fefc },
        .{ 0x00ff01, 0x00ffbe },
        .{ 0x00ffc2, 0x00ffc7 },
        .{ 0x00ffca, 0x00ffcf },
        .{ 0x00ffd2, 0x00ffd7 },
        .{ 0x00ffda, 0x00ffdc },
        .{ 0x00ffe0, 0x00ffe6 },
        .{ 0x00ffe8, 0x00ffee },
        .{ 0x00fff0, 0x00fff8 },
        .{ 0x010400, 0x010427 },
        .{ 0x0104b0, 0x0104d3 },
        .{ 0x010570, 0x01057a },
        .{ 0x01057c, 0x01058a },
        .{ 0x01058c, 0x010592 },
        .{ 0x010594, 0x010595 },
        .{ 0x010781, 0x010785 },
        .{ 0x010787, 0x0107b0 },
        .{ 0x0107b2, 0x0107ba },
        .{ 0x010c80, 0x010cb2 },
        .{ 0x010d50, 0x010d65 },
        .{ 0x0118a0, 0x0118bf },
        .{ 0x016e40, 0x016e5f },
        .{ 0x016ea0, 0x016eb8 },
        .{ 0x01bca0, 0x01bca3 },
        .{ 0x01ccd6, 0x01ccf9 },
        .{ 0x01d15e, 0x01d164 },
        .{ 0x01d173, 0x01d17a },
        .{ 0x01d1bb, 0x01d1c0 },
        .{ 0x01d400, 0x01d454 },
        .{ 0x01d456, 0x01d49c },
        .{ 0x01d49e, 0x01d49f },
        .{ 0x01d4a5, 0x01d4a6 },
        .{ 0x01d4a9, 0x01d4ac },
        .{ 0x01d4ae, 0x01d4b9 },
        .{ 0x01d4bd, 0x01d4c3 },
        .{ 0x01d4c5, 0x01d505 },
        .{ 0x01d507, 0x01d50a },
        .{ 0x01d50d, 0x01d514 },
        .{ 0x01d516, 0x01d51c },
        .{ 0x01d51e, 0x01d539 },
        .{ 0x01d53b, 0x01d53e },
        .{ 0x01d540, 0x01d544 },
        .{ 0x01d54a, 0x01d550 },
        .{ 0x01d552, 0x01d6a5 },
        .{ 0x01d6a8, 0x01d7cb },
        .{ 0x01d7ce, 0x01d7ff },
        .{ 0x01e030, 0x01e06d },
        .{ 0x01e900, 0x01e921 },
        .{ 0x01ee00, 0x01ee03 },
        .{ 0x01ee05, 0x01ee1f },
        .{ 0x01ee21, 0x01ee22 },
        .{ 0x01ee29, 0x01ee32 },
        .{ 0x01ee34, 0x01ee37 },
        .{ 0x01ee4d, 0x01ee4f },
        .{ 0x01ee51, 0x01ee52 },
        .{ 0x01ee61, 0x01ee62 },
        .{ 0x01ee67, 0x01ee6a },
        .{ 0x01ee6c, 0x01ee72 },
        .{ 0x01ee74, 0x01ee77 },
        .{ 0x01ee79, 0x01ee7c },
        .{ 0x01ee80, 0x01ee89 },
        .{ 0x01ee8b, 0x01ee9b },
        .{ 0x01eea1, 0x01eea3 },
        .{ 0x01eea5, 0x01eea9 },
        .{ 0x01eeab, 0x01eebb },
        .{ 0x01f100, 0x01f10a },
        .{ 0x01f110, 0x01f12e },
        .{ 0x01f130, 0x01f14f },
        .{ 0x01f16a, 0x01f16c },
        .{ 0x01f200, 0x01f202 },
        .{ 0x01f210, 0x01f23b },
        .{ 0x01f240, 0x01f248 },
        .{ 0x01f250, 0x01f251 },
        .{ 0x01fbf0, 0x01fbf9 },
        .{ 0x02f800, 0x02fa1d },
        .{ 0x0e0000, 0x0e0fff },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeGraphemeExtendCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x0005bf, 0x0005c7, 0x000670, 0x000711, 0x0007fd, 0x00093a, 0x00093c, 0x00094d,
        0x000981, 0x0009bc, 0x0009be, 0x0009cd, 0x0009d7, 0x0009fe, 0x000a3c, 0x000a51,
        0x000a75, 0x000abc, 0x000acd, 0x000b01, 0x000b3c, 0x000b4d, 0x000b82, 0x000bbe,
        0x000bc0, 0x000bcd, 0x000bd7, 0x000c00, 0x000c04, 0x000c3c, 0x000c81, 0x000cbc,
        0x000cc2, 0x000d3e, 0x000d4d, 0x000d57, 0x000d81, 0x000dca, 0x000dcf, 0x000dd6,
        0x000ddf, 0x000e31, 0x000eb1, 0x000f35, 0x000f37, 0x000f39, 0x000fc6, 0x001082,
        0x00108d, 0x00109d, 0x0017c6, 0x0017dd, 0x00180f, 0x0018a9, 0x001932, 0x001a1b,
        0x001a56, 0x001a60, 0x001a62, 0x001a7f, 0x001be6, 0x001bed, 0x001ced, 0x001cf4,
        0x00200c, 0x002d7f, 0x00a802, 0x00a806, 0x00a80b, 0x00a82c, 0x00a8ff, 0x00a953,
        0x00a9b3, 0x00a9c0, 0x00a9e5, 0x00aa43, 0x00aa4c, 0x00aa7c, 0x00aab0, 0x00aac1,
        0x00aaf6, 0x00abe5, 0x00abe8, 0x00abed, 0x00fb1e, 0x0101fd, 0x0102e0, 0x010a3f,
        0x011001, 0x011070, 0x0110c2, 0x011173, 0x0111c0, 0x0111cf, 0x01123e, 0x011241,
        0x0112df, 0x01133e, 0x011340, 0x01134d, 0x011357, 0x0113b8, 0x0113c2, 0x0113c5,
        0x0113d2, 0x011446, 0x01145e, 0x0114b0, 0x0114ba, 0x0114bd, 0x0115af, 0x01163d,
        0x0116ab, 0x0116ad, 0x01171d, 0x01171f, 0x011930, 0x011943, 0x0119e0, 0x011a47,
        0x011b60, 0x011b66, 0x011c3f, 0x011d3a, 0x011d47, 0x011d95, 0x011d97, 0x011f5a,
        0x013440, 0x016f4f, 0x016fe4, 0x01da75, 0x01da84, 0x01e08f, 0x01e2ae, 0x01e6e3,
        0x01e6e6, 0x01e6f5,
    };
    const ranges = [_][2]u21{
        .{ 0x000300, 0x00036f },
        .{ 0x000483, 0x000489 },
        .{ 0x000591, 0x0005bd },
        .{ 0x0005c1, 0x0005c2 },
        .{ 0x0005c4, 0x0005c5 },
        .{ 0x000610, 0x00061a },
        .{ 0x00064b, 0x00065f },
        .{ 0x0006d6, 0x0006dc },
        .{ 0x0006df, 0x0006e4 },
        .{ 0x0006e7, 0x0006e8 },
        .{ 0x0006ea, 0x0006ed },
        .{ 0x000730, 0x00074a },
        .{ 0x0007a6, 0x0007b0 },
        .{ 0x0007eb, 0x0007f3 },
        .{ 0x000816, 0x000819 },
        .{ 0x00081b, 0x000823 },
        .{ 0x000825, 0x000827 },
        .{ 0x000829, 0x00082d },
        .{ 0x000859, 0x00085b },
        .{ 0x000897, 0x00089f },
        .{ 0x0008ca, 0x0008e1 },
        .{ 0x0008e3, 0x000902 },
        .{ 0x000941, 0x000948 },
        .{ 0x000951, 0x000957 },
        .{ 0x000962, 0x000963 },
        .{ 0x0009c1, 0x0009c4 },
        .{ 0x0009e2, 0x0009e3 },
        .{ 0x000a01, 0x000a02 },
        .{ 0x000a41, 0x000a42 },
        .{ 0x000a47, 0x000a48 },
        .{ 0x000a4b, 0x000a4d },
        .{ 0x000a70, 0x000a71 },
        .{ 0x000a81, 0x000a82 },
        .{ 0x000ac1, 0x000ac5 },
        .{ 0x000ac7, 0x000ac8 },
        .{ 0x000ae2, 0x000ae3 },
        .{ 0x000afa, 0x000aff },
        .{ 0x000b3e, 0x000b3f },
        .{ 0x000b41, 0x000b44 },
        .{ 0x000b55, 0x000b57 },
        .{ 0x000b62, 0x000b63 },
        .{ 0x000c3e, 0x000c40 },
        .{ 0x000c46, 0x000c48 },
        .{ 0x000c4a, 0x000c4d },
        .{ 0x000c55, 0x000c56 },
        .{ 0x000c62, 0x000c63 },
        .{ 0x000cbf, 0x000cc0 },
        .{ 0x000cc6, 0x000cc8 },
        .{ 0x000cca, 0x000ccd },
        .{ 0x000cd5, 0x000cd6 },
        .{ 0x000ce2, 0x000ce3 },
        .{ 0x000d00, 0x000d01 },
        .{ 0x000d3b, 0x000d3c },
        .{ 0x000d41, 0x000d44 },
        .{ 0x000d62, 0x000d63 },
        .{ 0x000dd2, 0x000dd4 },
        .{ 0x000e34, 0x000e3a },
        .{ 0x000e47, 0x000e4e },
        .{ 0x000eb4, 0x000ebc },
        .{ 0x000ec8, 0x000ece },
        .{ 0x000f18, 0x000f19 },
        .{ 0x000f71, 0x000f7e },
        .{ 0x000f80, 0x000f84 },
        .{ 0x000f86, 0x000f87 },
        .{ 0x000f8d, 0x000f97 },
        .{ 0x000f99, 0x000fbc },
        .{ 0x00102d, 0x001030 },
        .{ 0x001032, 0x001037 },
        .{ 0x001039, 0x00103a },
        .{ 0x00103d, 0x00103e },
        .{ 0x001058, 0x001059 },
        .{ 0x00105e, 0x001060 },
        .{ 0x001071, 0x001074 },
        .{ 0x001085, 0x001086 },
        .{ 0x00135d, 0x00135f },
        .{ 0x001712, 0x001715 },
        .{ 0x001732, 0x001734 },
        .{ 0x001752, 0x001753 },
        .{ 0x001772, 0x001773 },
        .{ 0x0017b4, 0x0017b5 },
        .{ 0x0017b7, 0x0017bd },
        .{ 0x0017c9, 0x0017d3 },
        .{ 0x00180b, 0x00180d },
        .{ 0x001885, 0x001886 },
        .{ 0x001920, 0x001922 },
        .{ 0x001927, 0x001928 },
        .{ 0x001939, 0x00193b },
        .{ 0x001a17, 0x001a18 },
        .{ 0x001a58, 0x001a5e },
        .{ 0x001a65, 0x001a6c },
        .{ 0x001a73, 0x001a7c },
        .{ 0x001ab0, 0x001add },
        .{ 0x001ae0, 0x001aeb },
        .{ 0x001b00, 0x001b03 },
        .{ 0x001b34, 0x001b3d },
        .{ 0x001b42, 0x001b44 },
        .{ 0x001b6b, 0x001b73 },
        .{ 0x001b80, 0x001b81 },
        .{ 0x001ba2, 0x001ba5 },
        .{ 0x001ba8, 0x001bad },
        .{ 0x001be8, 0x001be9 },
        .{ 0x001bef, 0x001bf3 },
        .{ 0x001c2c, 0x001c33 },
        .{ 0x001c36, 0x001c37 },
        .{ 0x001cd0, 0x001cd2 },
        .{ 0x001cd4, 0x001ce0 },
        .{ 0x001ce2, 0x001ce8 },
        .{ 0x001cf8, 0x001cf9 },
        .{ 0x001dc0, 0x001dff },
        .{ 0x0020d0, 0x0020f0 },
        .{ 0x002cef, 0x002cf1 },
        .{ 0x002de0, 0x002dff },
        .{ 0x00302a, 0x00302f },
        .{ 0x003099, 0x00309a },
        .{ 0x00a66f, 0x00a672 },
        .{ 0x00a674, 0x00a67d },
        .{ 0x00a69e, 0x00a69f },
        .{ 0x00a6f0, 0x00a6f1 },
        .{ 0x00a825, 0x00a826 },
        .{ 0x00a8c4, 0x00a8c5 },
        .{ 0x00a8e0, 0x00a8f1 },
        .{ 0x00a926, 0x00a92d },
        .{ 0x00a947, 0x00a951 },
        .{ 0x00a980, 0x00a982 },
        .{ 0x00a9b6, 0x00a9b9 },
        .{ 0x00a9bc, 0x00a9bd },
        .{ 0x00aa29, 0x00aa2e },
        .{ 0x00aa31, 0x00aa32 },
        .{ 0x00aa35, 0x00aa36 },
        .{ 0x00aab2, 0x00aab4 },
        .{ 0x00aab7, 0x00aab8 },
        .{ 0x00aabe, 0x00aabf },
        .{ 0x00aaec, 0x00aaed },
        .{ 0x00fe00, 0x00fe0f },
        .{ 0x00fe20, 0x00fe2f },
        .{ 0x00ff9e, 0x00ff9f },
        .{ 0x010376, 0x01037a },
        .{ 0x010a01, 0x010a03 },
        .{ 0x010a05, 0x010a06 },
        .{ 0x010a0c, 0x010a0f },
        .{ 0x010a38, 0x010a3a },
        .{ 0x010ae5, 0x010ae6 },
        .{ 0x010d24, 0x010d27 },
        .{ 0x010d69, 0x010d6d },
        .{ 0x010eab, 0x010eac },
        .{ 0x010efa, 0x010eff },
        .{ 0x010f46, 0x010f50 },
        .{ 0x010f82, 0x010f85 },
        .{ 0x011038, 0x011046 },
        .{ 0x011073, 0x011074 },
        .{ 0x01107f, 0x011081 },
        .{ 0x0110b3, 0x0110b6 },
        .{ 0x0110b9, 0x0110ba },
        .{ 0x011100, 0x011102 },
        .{ 0x011127, 0x01112b },
        .{ 0x01112d, 0x011134 },
        .{ 0x011180, 0x011181 },
        .{ 0x0111b6, 0x0111be },
        .{ 0x0111c9, 0x0111cc },
        .{ 0x01122f, 0x011231 },
        .{ 0x011234, 0x011237 },
        .{ 0x0112e3, 0x0112ea },
        .{ 0x011300, 0x011301 },
        .{ 0x01133b, 0x01133c },
        .{ 0x011366, 0x01136c },
        .{ 0x011370, 0x011374 },
        .{ 0x0113bb, 0x0113c0 },
        .{ 0x0113c7, 0x0113c9 },
        .{ 0x0113ce, 0x0113d0 },
        .{ 0x0113e1, 0x0113e2 },
        .{ 0x011438, 0x01143f },
        .{ 0x011442, 0x011444 },
        .{ 0x0114b3, 0x0114b8 },
        .{ 0x0114bf, 0x0114c0 },
        .{ 0x0114c2, 0x0114c3 },
        .{ 0x0115b2, 0x0115b5 },
        .{ 0x0115bc, 0x0115bd },
        .{ 0x0115bf, 0x0115c0 },
        .{ 0x0115dc, 0x0115dd },
        .{ 0x011633, 0x01163a },
        .{ 0x01163f, 0x011640 },
        .{ 0x0116b0, 0x0116b7 },
        .{ 0x011722, 0x011725 },
        .{ 0x011727, 0x01172b },
        .{ 0x01182f, 0x011837 },
        .{ 0x011839, 0x01183a },
        .{ 0x01193b, 0x01193e },
        .{ 0x0119d4, 0x0119d7 },
        .{ 0x0119da, 0x0119db },
        .{ 0x011a01, 0x011a0a },
        .{ 0x011a33, 0x011a38 },
        .{ 0x011a3b, 0x011a3e },
        .{ 0x011a51, 0x011a56 },
        .{ 0x011a59, 0x011a5b },
        .{ 0x011a8a, 0x011a96 },
        .{ 0x011a98, 0x011a99 },
        .{ 0x011b62, 0x011b64 },
        .{ 0x011c30, 0x011c36 },
        .{ 0x011c38, 0x011c3d },
        .{ 0x011c92, 0x011ca7 },
        .{ 0x011caa, 0x011cb0 },
        .{ 0x011cb2, 0x011cb3 },
        .{ 0x011cb5, 0x011cb6 },
        .{ 0x011d31, 0x011d36 },
        .{ 0x011d3c, 0x011d3d },
        .{ 0x011d3f, 0x011d45 },
        .{ 0x011d90, 0x011d91 },
        .{ 0x011ef3, 0x011ef4 },
        .{ 0x011f00, 0x011f01 },
        .{ 0x011f36, 0x011f3a },
        .{ 0x011f40, 0x011f42 },
        .{ 0x013447, 0x013455 },
        .{ 0x01611e, 0x016129 },
        .{ 0x01612d, 0x01612f },
        .{ 0x016af0, 0x016af4 },
        .{ 0x016b30, 0x016b36 },
        .{ 0x016f8f, 0x016f92 },
        .{ 0x016ff0, 0x016ff1 },
        .{ 0x01bc9d, 0x01bc9e },
        .{ 0x01cf00, 0x01cf2d },
        .{ 0x01cf30, 0x01cf46 },
        .{ 0x01d165, 0x01d169 },
        .{ 0x01d16d, 0x01d172 },
        .{ 0x01d17b, 0x01d182 },
        .{ 0x01d185, 0x01d18b },
        .{ 0x01d1aa, 0x01d1ad },
        .{ 0x01d242, 0x01d244 },
        .{ 0x01da00, 0x01da36 },
        .{ 0x01da3b, 0x01da6c },
        .{ 0x01da9b, 0x01da9f },
        .{ 0x01daa1, 0x01daaf },
        .{ 0x01e000, 0x01e006 },
        .{ 0x01e008, 0x01e018 },
        .{ 0x01e01b, 0x01e021 },
        .{ 0x01e023, 0x01e024 },
        .{ 0x01e026, 0x01e02a },
        .{ 0x01e130, 0x01e136 },
        .{ 0x01e2ec, 0x01e2ef },
        .{ 0x01e4ec, 0x01e4ef },
        .{ 0x01e5ee, 0x01e5ef },
        .{ 0x01e6ee, 0x01e6ef },
        .{ 0x01e8d0, 0x01e8d6 },
        .{ 0x01e944, 0x01e94a },
        .{ 0x0e0020, 0x0e007f },
        .{ 0x0e0100, 0x0e01ef },
    };
    return codePointInUnicodeSet(code_point, &singles, &ranges);
}

pub fn isUnicodeExtenderCodePoint(code_point: u21) bool {
    return code_point == 0x0000b7 or
        code_point == 0x000640 or
        code_point == 0x0007fa or
        code_point == 0x000a71 or
        code_point == 0x000afb or
        code_point == 0x000b55 or
        code_point == 0x000e46 or
        code_point == 0x000ec6 or
        code_point == 0x00180a or
        code_point == 0x001843 or
        code_point == 0x001aa7 or
        code_point == 0x001c36 or
        code_point == 0x001c7b or
        code_point == 0x003005 or
        code_point == 0x00a015 or
        code_point == 0x00a60c or
        code_point == 0x00a9cf or
        code_point == 0x00a9e6 or
        code_point == 0x00aa70 or
        code_point == 0x00aadd or
        code_point == 0x00ff70 or
        code_point == 0x010d4e or
        code_point == 0x010d6a or
        code_point == 0x010d6f or
        code_point == 0x011237 or
        code_point == 0x01135d or
        code_point == 0x011a98 or
        code_point == 0x011dd9 or
        code_point == 0x016fe3 or
        code_point == 0x01e5ef or
        (code_point >= 0x0002d0 and code_point <= 0x0002d1) or
        (code_point >= 0x003031 and code_point <= 0x003035) or
        (code_point >= 0x00309d and code_point <= 0x00309e) or
        (code_point >= 0x0030fc and code_point <= 0x0030fe) or
        (code_point >= 0x00aaf3 and code_point <= 0x00aaf4) or
        (code_point >= 0x010781 and code_point <= 0x010782) or
        (code_point >= 0x0113d2 and code_point <= 0x0113d3) or
        (code_point >= 0x0115c6 and code_point <= 0x0115c8) or
        (code_point >= 0x016b42 and code_point <= 0x016b43) or
        (code_point >= 0x016fe0 and code_point <= 0x016fe1) or
        (code_point >= 0x016ff2 and code_point <= 0x016ff3) or
        (code_point >= 0x01e13c and code_point <= 0x01e13d) or
        (code_point >= 0x01e944 and code_point <= 0x01e946);
}

pub fn isUnicodeMathCodePoint(code_point: u21) bool {
    return code_point == 0x00002b or
        code_point == 0x00005e or
        code_point == 0x00007c or
        code_point == 0x00007e or
        code_point == 0x0000ac or
        code_point == 0x0000b1 or
        code_point == 0x0000d7 or
        code_point == 0x0000f7 or
        code_point == 0x0003d5 or
        code_point == 0x002016 or
        code_point == 0x002040 or
        code_point == 0x002044 or
        code_point == 0x002052 or
        code_point == 0x0020e1 or
        code_point == 0x002102 or
        code_point == 0x002107 or
        code_point == 0x002115 or
        code_point == 0x002124 or
        code_point == 0x00214b or
        code_point == 0x0021dd or
        code_point == 0x00237c or
        code_point == 0x0023b7 or
        code_point == 0x0023d0 or
        code_point == 0x0025e2 or
        code_point == 0x0025e4 or
        code_point == 0x002640 or
        code_point == 0x002642 or
        code_point == 0x00fb29 or
        code_point == 0x00fe68 or
        code_point == 0x00ff0b or
        code_point == 0x00ff3c or
        code_point == 0x00ff3e or
        code_point == 0x00ff5c or
        code_point == 0x00ff5e or
        code_point == 0x00ffe2 or
        code_point == 0x01cef0 or
        code_point == 0x01d4a2 or
        code_point == 0x01d4bb or
        code_point == 0x01d546 or
        code_point == 0x01ee24 or
        code_point == 0x01ee27 or
        code_point == 0x01ee39 or
        code_point == 0x01ee3b or
        code_point == 0x01ee42 or
        code_point == 0x01ee47 or
        code_point == 0x01ee49 or
        code_point == 0x01ee4b or
        code_point == 0x01ee54 or
        code_point == 0x01ee57 or
        code_point == 0x01ee59 or
        code_point == 0x01ee5b or
        code_point == 0x01ee5d or
        code_point == 0x01ee5f or
        code_point == 0x01ee64 or
        code_point == 0x01ee7e or
        (code_point >= 0x00003c and code_point <= 0x00003e) or
        (code_point >= 0x0003d0 and code_point <= 0x0003d2) or
        (code_point >= 0x0003f0 and code_point <= 0x0003f1) or
        (code_point >= 0x0003f4 and code_point <= 0x0003f6) or
        (code_point >= 0x000606 and code_point <= 0x000608) or
        (code_point >= 0x002032 and code_point <= 0x002034) or
        (code_point >= 0x002061 and code_point <= 0x002064) or
        (code_point >= 0x00207a and code_point <= 0x00207e) or
        (code_point >= 0x00208a and code_point <= 0x00208e) or
        (code_point >= 0x0020d0 and code_point <= 0x0020dc) or
        (code_point >= 0x0020e5 and code_point <= 0x0020e6) or
        (code_point >= 0x0020eb and code_point <= 0x0020ef) or
        (code_point >= 0x00210a and code_point <= 0x002113) or
        (code_point >= 0x002118 and code_point <= 0x00211d) or
        (code_point >= 0x002128 and code_point <= 0x002129) or
        (code_point >= 0x00212c and code_point <= 0x00212d) or
        (code_point >= 0x00212f and code_point <= 0x002131) or
        (code_point >= 0x002133 and code_point <= 0x002138) or
        (code_point >= 0x00213c and code_point <= 0x002149) or
        (code_point >= 0x002190 and code_point <= 0x0021a7) or
        (code_point >= 0x0021a9 and code_point <= 0x0021ae) or
        (code_point >= 0x0021b0 and code_point <= 0x0021b1) or
        (code_point >= 0x0021b6 and code_point <= 0x0021b7) or
        (code_point >= 0x0021bc and code_point <= 0x0021db) or
        (code_point >= 0x0021e4 and code_point <= 0x0021e5) or
        (code_point >= 0x0021f4 and code_point <= 0x0022ff) or
        (code_point >= 0x002308 and code_point <= 0x00230b) or
        (code_point >= 0x002320 and code_point <= 0x002321) or
        (code_point >= 0x00239b and code_point <= 0x0023b5) or
        (code_point >= 0x0023dc and code_point <= 0x0023e2) or
        (code_point >= 0x0025a0 and code_point <= 0x0025a1) or
        (code_point >= 0x0025ae and code_point <= 0x0025b7) or
        (code_point >= 0x0025bc and code_point <= 0x0025c1) or
        (code_point >= 0x0025c6 and code_point <= 0x0025c7) or
        (code_point >= 0x0025ca and code_point <= 0x0025cb) or
        (code_point >= 0x0025cf and code_point <= 0x0025d3) or
        (code_point >= 0x0025e7 and code_point <= 0x0025ec) or
        (code_point >= 0x0025f8 and code_point <= 0x0025ff) or
        (code_point >= 0x002605 and code_point <= 0x002606) or
        (code_point >= 0x002660 and code_point <= 0x002663) or
        (code_point >= 0x00266d and code_point <= 0x00266f) or
        (code_point >= 0x0027c0 and code_point <= 0x0027ff) or
        (code_point >= 0x002900 and code_point <= 0x002aff) or
        (code_point >= 0x002b30 and code_point <= 0x002b44) or
        (code_point >= 0x002b47 and code_point <= 0x002b4c) or
        (code_point >= 0x00fe61 and code_point <= 0x00fe66) or
        (code_point >= 0x00ff1c and code_point <= 0x00ff1e) or
        (code_point >= 0x00ffe9 and code_point <= 0x00ffec) or
        (code_point >= 0x010d8e and code_point <= 0x010d8f) or
        (code_point >= 0x01d400 and code_point <= 0x01d454) or
        (code_point >= 0x01d456 and code_point <= 0x01d49c) or
        (code_point >= 0x01d49e and code_point <= 0x01d49f) or
        (code_point >= 0x01d4a5 and code_point <= 0x01d4a6) or
        (code_point >= 0x01d4a9 and code_point <= 0x01d4ac) or
        (code_point >= 0x01d4ae and code_point <= 0x01d4b9) or
        (code_point >= 0x01d4bd and code_point <= 0x01d4c3) or
        (code_point >= 0x01d4c5 and code_point <= 0x01d505) or
        (code_point >= 0x01d507 and code_point <= 0x01d50a) or
        (code_point >= 0x01d50d and code_point <= 0x01d514) or
        (code_point >= 0x01d516 and code_point <= 0x01d51c) or
        (code_point >= 0x01d51e and code_point <= 0x01d539) or
        (code_point >= 0x01d53b and code_point <= 0x01d53e) or
        (code_point >= 0x01d540 and code_point <= 0x01d544) or
        (code_point >= 0x01d54a and code_point <= 0x01d550) or
        (code_point >= 0x01d552 and code_point <= 0x01d6a5) or
        (code_point >= 0x01d6a8 and code_point <= 0x01d7cb) or
        (code_point >= 0x01d7ce and code_point <= 0x01d7ff) or
        (code_point >= 0x01ee00 and code_point <= 0x01ee03) or
        (code_point >= 0x01ee05 and code_point <= 0x01ee1f) or
        (code_point >= 0x01ee21 and code_point <= 0x01ee22) or
        (code_point >= 0x01ee29 and code_point <= 0x01ee32) or
        (code_point >= 0x01ee34 and code_point <= 0x01ee37) or
        (code_point >= 0x01ee4d and code_point <= 0x01ee4f) or
        (code_point >= 0x01ee51 and code_point <= 0x01ee52) or
        (code_point >= 0x01ee61 and code_point <= 0x01ee62) or
        (code_point >= 0x01ee67 and code_point <= 0x01ee6a) or
        (code_point >= 0x01ee6c and code_point <= 0x01ee72) or
        (code_point >= 0x01ee74 and code_point <= 0x01ee77) or
        (code_point >= 0x01ee79 and code_point <= 0x01ee7c) or
        (code_point >= 0x01ee80 and code_point <= 0x01ee89) or
        (code_point >= 0x01ee8b and code_point <= 0x01ee9b) or
        (code_point >= 0x01eea1 and code_point <= 0x01eea3) or
        (code_point >= 0x01eea5 and code_point <= 0x01eea9) or
        (code_point >= 0x01eeab and code_point <= 0x01eebb) or
        (code_point >= 0x01eef0 and code_point <= 0x01eef1) or
        (code_point >= 0x01f8d0 and code_point <= 0x01f8d8);
}

pub fn isUnicodeIdeographicCodePoint(code_point: u21) bool {
    return code_point == 0x016fe4 or
        (code_point >= 0x003006 and code_point <= 0x003007) or
        (code_point >= 0x003021 and code_point <= 0x003029) or
        (code_point >= 0x003038 and code_point <= 0x00303a) or
        (code_point >= 0x003400 and code_point <= 0x004dbf) or
        (code_point >= 0x004e00 and code_point <= 0x009fff) or
        (code_point >= 0x00f900 and code_point <= 0x00fa6d) or
        (code_point >= 0x00fa70 and code_point <= 0x00fad9) or
        (code_point >= 0x016ff2 and code_point <= 0x016ff6) or
        (code_point >= 0x017000 and code_point <= 0x018cd5) or
        (code_point >= 0x018cff and code_point <= 0x018d1e) or
        (code_point >= 0x018d80 and code_point <= 0x018df2) or
        (code_point >= 0x01b170 and code_point <= 0x01b2fb) or
        (code_point >= 0x020000 and code_point <= 0x02a6df) or
        (code_point >= 0x02a700 and code_point <= 0x02b81d) or
        (code_point >= 0x02b820 and code_point <= 0x02cead) or
        (code_point >= 0x02ceb0 and code_point <= 0x02ebe0) or
        (code_point >= 0x02ebf0 and code_point <= 0x02ee5d) or
        (code_point >= 0x02f800 and code_point <= 0x02fa1d) or
        (code_point >= 0x030000 and code_point <= 0x03134a) or
        (code_point >= 0x031350 and code_point <= 0x033479);
}

pub fn isUnicodeUnifiedIdeographCodePoint(code_point: u21) bool {
    return code_point == 0x00fa11 or
        code_point == 0x00fa1f or
        code_point == 0x00fa21 or
        (code_point >= 0x003400 and code_point <= 0x004dbf) or
        (code_point >= 0x004e00 and code_point <= 0x009fff) or
        (code_point >= 0x00fa0e and code_point <= 0x00fa0f) or
        (code_point >= 0x00fa13 and code_point <= 0x00fa14) or
        (code_point >= 0x00fa23 and code_point <= 0x00fa24) or
        (code_point >= 0x00fa27 and code_point <= 0x00fa29) or
        (code_point >= 0x020000 and code_point <= 0x02a6df) or
        (code_point >= 0x02a700 and code_point <= 0x02b81d) or
        (code_point >= 0x02b820 and code_point <= 0x02cead) or
        (code_point >= 0x02ceb0 and code_point <= 0x02ebe0) or
        (code_point >= 0x02ebf0 and code_point <= 0x02ee5d) or
        (code_point >= 0x030000 and code_point <= 0x03134a) or
        (code_point >= 0x031350 and code_point <= 0x033479);
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
    if (std.mem.eql(u8, name, "normalize")) return 37;
    if (std.mem.eql(u8, name, "isWellFormed")) return 38;
    if (std.mem.eql(u8, name, "toWellFormed")) return 39;
    if (std.mem.eql(u8, name, "search")) return 40;
    if (std.mem.eql(u8, name, "match")) return 41;
    if (std.mem.eql(u8, name, "replaceAll")) return 42;
    if (std.mem.eql(u8, name, "matchAll")) return 43;
    return null;
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
    if (std.mem.eql(u8, name, "split")) return 27;
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

pub fn test262AgentStringArg(rt: *core.JSRuntime, value: core.JSValue) ![]u8 {
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(rt.memory.allocator);
    try value_ops.appendValueString(rt, &bytes, value);
    return bytes.toOwnedSlice(rt.memory.allocator);
}

pub fn test262AgentStringValue(rt: *core.JSRuntime, value: core.JSValue) ![]u8 {
    const local = try test262AgentStringArg(rt, value);
    defer rt.memory.allocator.free(local);
    return try test262PageAllocator().dupe(u8, local);
}

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
        // strings. Hot loops like `decimalToPercentHexString` (test262's
        // URI sweep) hit this path thousands of times per inner
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