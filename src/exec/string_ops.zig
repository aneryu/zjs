const std = @import("std");

const regexp_properties = @import("../libs/unicode.zig").regexp_properties;
const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const string_id_lookup = core.host_function.builtin_method_id_lookup.string;
const regexp_adapter = @import("regexp_adapter.zig");
const unicode_lib = @import("../libs/unicode.zig");
const call_mod = @import("call.zig");
const exception_ops = @import("vm_exception_ops.zig");
const frame_mod = @import("frame.zig");
const iter_vm = @import("iterator_ops.zig");
const property_ops = @import("property_ops.zig");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("coercion_ops.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const object_ops = @import("object_ops.zig");
const regexp_fastpath = @import("regexp_fastpath.zig");
const RegExpCapture = call_runtime.RegExpCapture;
const ValueSliceRoot = array_ops.ValueSliceRoot;
const anchoredBinaryPropertyName = object_ops.anchoredBinaryPropertyName;
const appendBacktraceFunctionName = error_stack_ops.appendBacktraceFunctionName;
const appendCallSiteFileName = error_stack_ops.appendCallSiteFileName;
const appendCallSiteFunctionName = error_stack_ops.appendCallSiteFunctionName;
const appendNamedCaptureSubstitution = regexp_fastpath.appendNamedCaptureSubstitution;
const appendRegExpFlags = regexp_fastpath.appendRegExpFlags;
const appendRegExpSource = regexp_fastpath.appendRegExpSource;
const arrayFirstIndexStart = array_ops.arrayFirstIndexStart;
const arrayLastIndexStart = array_ops.arrayLastIndexStart;
const arrayMethodTypedArrayLength = array_ops.arrayMethodTypedArrayLength;
const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
const arrayPrototypeRecordId = array_ops.arrayPrototypeRecordId;
const arraySpeciesCreate = array_ops.arraySpeciesCreate;
const arraySpeciesOriginalIsArray = array_ops.arraySpeciesOriginalIsArray;
const atomIdOrNameEql = call_runtime.atomIdOrNameEql;
const backtraceFunctionNameEql = error_stack_ops.backtraceFunctionNameEql;
const bytecodeFunctionObjectTag = object_ops.bytecodeFunctionObjectTag;
const callObjectToPrimitiveMethod = object_ops.callObjectToPrimitiveMethod;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const callableObjectFromValue = object_ops.callableObjectFromValue;
const clearRegExpLegacySlot = regexp_fastpath.clearRegExpLegacySlot;
const constructValueOrBytecode = call_runtime.constructValueOrBytecode;
const constructorPrototypeFromGlobal = object_ops.constructorPrototypeFromGlobal;
const createDataPropertyOrThrow = object_ops.createDataPropertyOrThrow;
const createIteratorResult = call_runtime.createIteratorResult;
const createRegExpIndicesArray = array_ops.createRegExpIndicesArray;
const defineFreshNonIndexDataProperty = object_ops.defineFreshNonIndexDataProperty;
const defineNativeDataMethod = builtin_glue.defineNativeDataMethod;
const defineRegExpGroupsProperty = object_ops.defineRegExpGroupsProperty;
const defineRegExpGroupsPropertyFromValue = object_ops.defineRegExpGroupsPropertyFromValue;
const errorStackTraceLimit = error_stack_ops.errorStackTraceLimit;
const getIteratorMethod = call_runtime.getIteratorMethod;
const getValueProperty = object_ops.getValueProperty;
const hasValueProperty = object_ops.hasValueProperty;
const isAdlamScriptExtensionsName = call_runtime.isAdlamScriptExtensionsName;
const isArabicScriptExtensionsName = call_runtime.isArabicScriptExtensionsName;
const isArmenianScriptExtensionsName = call_runtime.isArmenianScriptExtensionsName;
const isArrayPrototypeRecord = array_ops.isArrayPrototypeRecord;
const isAvestanScriptExtensionsName = call_runtime.isAvestanScriptExtensionsName;
const isBengaliScriptExtensionsName = call_runtime.isBengaliScriptExtensionsName;
const isBopomofoScriptExtensionsName = call_runtime.isBopomofoScriptExtensionsName;
const isBugineseScriptExtensionsName = call_runtime.isBugineseScriptExtensionsName;
const isCallableValue = call_runtime.isCallableValue;
const isCarianScriptExtensionsName = call_runtime.isCarianScriptExtensionsName;
const isCaucasianAlbanianScriptExtensionsName = call_runtime.isCaucasianAlbanianScriptExtensionsName;
const isChakmaScriptExtensionsName = call_runtime.isChakmaScriptExtensionsName;
const isCherokeeScriptExtensionsName = call_runtime.isCherokeeScriptExtensionsName;
const isCommonScriptExtensionsName = call_runtime.isCommonScriptExtensionsName;
const isControlGeneralCategoryName = call_runtime.isControlGeneralCategoryName;
const isCopticScriptExtensionsName = call_runtime.isCopticScriptExtensionsName;
const isCopticScriptName = call_runtime.isCopticScriptName;
const isCypriotScriptExtensionsName = call_runtime.isCypriotScriptExtensionsName;
const isCyrillicScriptExtensionsName = call_runtime.isCyrillicScriptExtensionsName;
const isDecimalNumberGeneralCategoryName = call_runtime.isDecimalNumberGeneralCategoryName;
const isDevanagariScriptExtensionsName = call_runtime.isDevanagariScriptExtensionsName;
const isDograScriptExtensionsName = call_runtime.isDograScriptExtensionsName;
const isDuployanScriptExtensionsName = call_runtime.isDuployanScriptExtensionsName;
const isElbasanScriptExtensionsName = call_runtime.isElbasanScriptExtensionsName;
const isEthiopicScriptExtensionsName = call_runtime.isEthiopicScriptExtensionsName;
const isGarayScriptExtensionsName = call_runtime.isGarayScriptExtensionsName;
const isGeorgianScriptExtensionsName = call_runtime.isGeorgianScriptExtensionsName;
const isGlagoliticScriptExtensionsName = call_runtime.isGlagoliticScriptExtensionsName;
const isGothicScriptExtensionsName = call_runtime.isGothicScriptExtensionsName;
const isGranthaScriptExtensionsName = call_runtime.isGranthaScriptExtensionsName;
const isGraphemeBaseName = call_runtime.isGraphemeBaseName;
const isGreekScriptExtensionsName = call_runtime.isGreekScriptExtensionsName;
const isGujaratiScriptExtensionsName = call_runtime.isGujaratiScriptExtensionsName;
const isGunjalaGondiScriptExtensionsName = call_runtime.isGunjalaGondiScriptExtensionsName;
const isGurmukhiScriptExtensionsName = call_runtime.isGurmukhiScriptExtensionsName;
const isHanScriptExtensionsName = call_runtime.isHanScriptExtensionsName;
const isHanScriptName = call_runtime.isHanScriptName;
const isHangulScriptExtensionsName = call_runtime.isHangulScriptExtensionsName;
const isHanifiRohingyaScriptExtensionsName = call_runtime.isHanifiRohingyaScriptExtensionsName;
const isHanunooScriptExtensionsName = call_runtime.isHanunooScriptExtensionsName;
const isHebrewScriptExtensionsName = call_runtime.isHebrewScriptExtensionsName;
const isHiraganaScriptExtensionsName = call_runtime.isHiraganaScriptExtensionsName;
const isIdContinueName = call_runtime.isIdContinueName;
const isImperialAramaicScriptExtensionsName = call_runtime.isImperialAramaicScriptExtensionsName;
const isInheritedScriptExtensionsName = call_runtime.isInheritedScriptExtensionsName;
const isInheritedScriptName = call_runtime.isInheritedScriptName;
const isJavaneseScriptExtensionsName = call_runtime.isJavaneseScriptExtensionsName;
const isKaithiScriptExtensionsName = call_runtime.isKaithiScriptExtensionsName;
const isKannadaScriptExtensionsName = call_runtime.isKannadaScriptExtensionsName;
const isKatakanaScriptExtensionsName = call_runtime.isKatakanaScriptExtensionsName;
const isKawiScriptExtensionsName = call_runtime.isKawiScriptExtensionsName;
const isKayahLiScriptExtensionsName = call_runtime.isKayahLiScriptExtensionsName;
const isKhojkiScriptExtensionsName = call_runtime.isKhojkiScriptExtensionsName;
const isKhudawadiScriptExtensionsName = call_runtime.isKhudawadiScriptExtensionsName;
const isKiratRaiScriptName = call_runtime.isKiratRaiScriptName;
const isLaoScriptExtensionsName = call_runtime.isLaoScriptExtensionsName;
const isLatinScriptExtensionsName = call_runtime.isLatinScriptExtensionsName;
const isLetterGeneralCategoryName = call_runtime.isLetterGeneralCategoryName;
const isLimbuScriptExtensionsName = call_runtime.isLimbuScriptExtensionsName;
const isLinearAScriptExtensionsName = call_runtime.isLinearAScriptExtensionsName;
const isLinearBScriptExtensionsName = call_runtime.isLinearBScriptExtensionsName;
const isLisuScriptExtensionsName = call_runtime.isLisuScriptExtensionsName;
const isLycianScriptExtensionsName = call_runtime.isLycianScriptExtensionsName;
const isLydianScriptExtensionsName = call_runtime.isLydianScriptExtensionsName;
const isMahajaniScriptExtensionsName = call_runtime.isMahajaniScriptExtensionsName;
const isMalayalamScriptExtensionsName = call_runtime.isMalayalamScriptExtensionsName;
const isMandaicScriptExtensionsName = call_runtime.isMandaicScriptExtensionsName;
const isManichaeanScriptExtensionsName = call_runtime.isManichaeanScriptExtensionsName;
const isMarkGeneralCategoryName = call_runtime.isMarkGeneralCategoryName;
const isMasaramGondiScriptExtensionsName = call_runtime.isMasaramGondiScriptExtensionsName;
const isMedefaidrinScriptExtensionsName = call_runtime.isMedefaidrinScriptExtensionsName;
const isMeeteiMayekScriptExtensionsName = call_runtime.isMeeteiMayekScriptExtensionsName;
const isMendeKikakuiScriptExtensionsName = call_runtime.isMendeKikakuiScriptExtensionsName;
const isMeroiticCursiveScriptExtensionsName = call_runtime.isMeroiticCursiveScriptExtensionsName;
const isMeroiticHieroglyphsScriptExtensionsName = call_runtime.isMeroiticHieroglyphsScriptExtensionsName;
const isMiaoScriptExtensionsName = call_runtime.isMiaoScriptExtensionsName;
const isMiaoScriptName = call_runtime.isMiaoScriptName;
const isModiScriptExtensionsName = call_runtime.isModiScriptExtensionsName;
const isMongolianScriptExtensionsName = call_runtime.isMongolianScriptExtensionsName;
const isMroScriptExtensionsName = call_runtime.isMroScriptExtensionsName;
const isMultaniScriptExtensionsName = call_runtime.isMultaniScriptExtensionsName;
const isMyanmarScriptExtensionsName = call_runtime.isMyanmarScriptExtensionsName;
const isNabataeanScriptExtensionsName = call_runtime.isNabataeanScriptExtensionsName;
const isNagMundariScriptExtensionsName = call_runtime.isNagMundariScriptExtensionsName;
const isNandinagariScriptExtensionsName = call_runtime.isNandinagariScriptExtensionsName;
const isNandinagariScriptName = call_runtime.isNandinagariScriptName;
const isNewTaiLueScriptExtensionsName = call_runtime.isNewTaiLueScriptExtensionsName;
const isNewTaiLueScriptName = call_runtime.isNewTaiLueScriptName;
const isNewaScriptExtensionsName = call_runtime.isNewaScriptExtensionsName;
const isNewaScriptName = call_runtime.isNewaScriptName;
const isNkoScriptExtensionsName = call_runtime.isNkoScriptExtensionsName;
const isNkoScriptName = call_runtime.isNkoScriptName;
const isNumberCategoryName = call_runtime.isNumberCategoryName;
const isNushuScriptExtensionsName = call_runtime.isNushuScriptExtensionsName;
const isNushuScriptName = call_runtime.isNushuScriptName;
const isNyiakengPuachueHmongScriptExtensionsName = call_runtime.isNyiakengPuachueHmongScriptExtensionsName;
const isNyiakengPuachueHmongScriptName = call_runtime.isNyiakengPuachueHmongScriptName;
const isOghamScriptExtensionsName = call_runtime.isOghamScriptExtensionsName;
const isOghamScriptName = call_runtime.isOghamScriptName;
const isOlChikiScriptExtensionsName = call_runtime.isOlChikiScriptExtensionsName;
const isOlChikiScriptName = call_runtime.isOlChikiScriptName;
const isOlOnalScriptExtensionsName = call_runtime.isOlOnalScriptExtensionsName;
const isOlOnalScriptName = call_runtime.isOlOnalScriptName;
const isOldHungarianScriptExtensionsName = call_runtime.isOldHungarianScriptExtensionsName;
const isOldHungarianScriptName = call_runtime.isOldHungarianScriptName;
const isOldItalicScriptExtensionsName = call_runtime.isOldItalicScriptExtensionsName;
const isOldItalicScriptName = call_runtime.isOldItalicScriptName;
const isOldNorthArabianScriptExtensionsName = call_runtime.isOldNorthArabianScriptExtensionsName;
const isOldNorthArabianScriptName = call_runtime.isOldNorthArabianScriptName;
const isOldPermicScriptExtensionsName = call_runtime.isOldPermicScriptExtensionsName;
const isOldPermicScriptName = call_runtime.isOldPermicScriptName;
const isOldPersianScriptExtensionsName = call_runtime.isOldPersianScriptExtensionsName;
const isOldPersianScriptName = call_runtime.isOldPersianScriptName;
const isOldSogdianScriptExtensionsName = call_runtime.isOldSogdianScriptExtensionsName;
const isOldSogdianScriptName = call_runtime.isOldSogdianScriptName;
const isOldSouthArabianScriptExtensionsName = call_runtime.isOldSouthArabianScriptExtensionsName;
const isOldSouthArabianScriptName = call_runtime.isOldSouthArabianScriptName;
const isOldTurkicScriptExtensionsName = call_runtime.isOldTurkicScriptExtensionsName;
const isOldTurkicScriptName = call_runtime.isOldTurkicScriptName;
const isOldUyghurScriptExtensionsName = call_runtime.isOldUyghurScriptExtensionsName;
const isOldUyghurScriptName = call_runtime.isOldUyghurScriptName;
const isOriyaScriptExtensionsName = call_runtime.isOriyaScriptExtensionsName;
const isOriyaScriptName = call_runtime.isOriyaScriptName;
const isOsageScriptExtensionsName = call_runtime.isOsageScriptExtensionsName;
const isOsageScriptName = call_runtime.isOsageScriptName;
const isOsmanyaScriptExtensionsName = call_runtime.isOsmanyaScriptExtensionsName;
const isOsmanyaScriptName = call_runtime.isOsmanyaScriptName;
const isOtherGeneralCategoryName = call_runtime.isOtherGeneralCategoryName;
const isOtherLetterGeneralCategoryName = call_runtime.isOtherLetterGeneralCategoryName;
const isPahawhHmongScriptExtensionsName = call_runtime.isPahawhHmongScriptExtensionsName;
const isPahawhHmongScriptName = call_runtime.isPahawhHmongScriptName;
const isPalmyreneScriptExtensionsName = call_runtime.isPalmyreneScriptExtensionsName;
const isPalmyreneScriptName = call_runtime.isPalmyreneScriptName;
const isPauCinHauScriptExtensionsName = call_runtime.isPauCinHauScriptExtensionsName;
const isPauCinHauScriptName = call_runtime.isPauCinHauScriptName;
const isPhagsPaScriptExtensionsName = call_runtime.isPhagsPaScriptExtensionsName;
const isPhagsPaScriptName = call_runtime.isPhagsPaScriptName;
const isPhoenicianScriptExtensionsName = call_runtime.isPhoenicianScriptExtensionsName;
const isPhoenicianScriptName = call_runtime.isPhoenicianScriptName;
const isPsalterPahlaviScriptExtensionsName = call_runtime.isPsalterPahlaviScriptExtensionsName;
const isPsalterPahlaviScriptName = call_runtime.isPsalterPahlaviScriptName;
const isPunctuationGeneralCategoryName = call_runtime.isPunctuationGeneralCategoryName;
const isRegExpLineTerminator = regexp_fastpath.isRegExpLineTerminator;
const isRegExpObservable = regexp_fastpath.isRegExpObservable;
const isRejangScriptExtensionsName = call_runtime.isRejangScriptExtensionsName;
const isRejangScriptName = call_runtime.isRejangScriptName;
const isRunicScriptExtensionsName = call_runtime.isRunicScriptExtensionsName;
const isRunicScriptName = call_runtime.isRunicScriptName;
const isSamaritanScriptExtensionsName = call_runtime.isSamaritanScriptExtensionsName;
const isSamaritanScriptName = call_runtime.isSamaritanScriptName;
const isSaurashtraScriptExtensionsName = call_runtime.isSaurashtraScriptExtensionsName;
const isSaurashtraScriptName = call_runtime.isSaurashtraScriptName;
const isSharadaScriptExtensionsName = call_runtime.isSharadaScriptExtensionsName;
const isSharadaScriptName = call_runtime.isSharadaScriptName;
const isShavianScriptExtensionsName = call_runtime.isShavianScriptExtensionsName;
const isShavianScriptName = call_runtime.isShavianScriptName;
const isSiddhamScriptExtensionsName = call_runtime.isSiddhamScriptExtensionsName;
const isSiddhamScriptName = call_runtime.isSiddhamScriptName;
const isSideticScriptExtensionsName = call_runtime.isSideticScriptExtensionsName;
const isSideticScriptName = call_runtime.isSideticScriptName;
const isSignWritingScriptExtensionsName = call_runtime.isSignWritingScriptExtensionsName;
const isSignWritingScriptName = call_runtime.isSignWritingScriptName;
const isSinhalaScriptExtensionsName = call_runtime.isSinhalaScriptExtensionsName;
const isSinhalaScriptName = call_runtime.isSinhalaScriptName;
const isSogdianScriptExtensionsName = call_runtime.isSogdianScriptExtensionsName;
const isSogdianScriptName = call_runtime.isSogdianScriptName;
const isSoraSompengScriptExtensionsName = call_runtime.isSoraSompengScriptExtensionsName;
const isSoraSompengScriptName = call_runtime.isSoraSompengScriptName;
const isSoyomboScriptExtensionsName = call_runtime.isSoyomboScriptExtensionsName;
const isSoyomboScriptName = call_runtime.isSoyomboScriptName;
const isSundaneseScriptExtensionsName = call_runtime.isSundaneseScriptExtensionsName;
const isSundaneseScriptName = call_runtime.isSundaneseScriptName;
const isSunuwarScriptExtensionsName = call_runtime.isSunuwarScriptExtensionsName;
const isSunuwarScriptName = call_runtime.isSunuwarScriptName;
const isSylotiNagriScriptExtensionsName = call_runtime.isSylotiNagriScriptExtensionsName;
const isSylotiNagriScriptName = call_runtime.isSylotiNagriScriptName;
const isSymbolGeneralCategoryName = call_runtime.isSymbolGeneralCategoryName;
const isSyriacScriptExtensionsName = call_runtime.isSyriacScriptExtensionsName;
const isSyriacScriptName = call_runtime.isSyriacScriptName;
const isTagalogScriptExtensionsName = call_runtime.isTagalogScriptExtensionsName;
const isTagalogScriptName = call_runtime.isTagalogScriptName;
const isTagbanwaScriptExtensionsName = call_runtime.isTagbanwaScriptExtensionsName;
const isTagbanwaScriptName = call_runtime.isTagbanwaScriptName;
const isTaiLeScriptExtensionsName = call_runtime.isTaiLeScriptExtensionsName;
const isTaiLeScriptName = call_runtime.isTaiLeScriptName;
const isTaiThamScriptExtensionsName = call_runtime.isTaiThamScriptExtensionsName;
const isTaiThamScriptName = call_runtime.isTaiThamScriptName;
const isTaiVietScriptExtensionsName = call_runtime.isTaiVietScriptExtensionsName;
const isTaiVietScriptName = call_runtime.isTaiVietScriptName;
const isTaiYoScriptExtensionsName = call_runtime.isTaiYoScriptExtensionsName;
const isTaiYoScriptName = call_runtime.isTaiYoScriptName;
const isTakriScriptExtensionsName = call_runtime.isTakriScriptExtensionsName;
const isTakriScriptName = call_runtime.isTakriScriptName;
const isTamilScriptExtensionsName = call_runtime.isTamilScriptExtensionsName;
const isTamilScriptName = call_runtime.isTamilScriptName;
const isTangsaScriptExtensionsName = call_runtime.isTangsaScriptExtensionsName;
const isTangsaScriptName = call_runtime.isTangsaScriptName;
const isTangutScriptExtensionsName = call_runtime.isTangutScriptExtensionsName;
const isTangutScriptName = call_runtime.isTangutScriptName;
const isTeluguScriptExtensionsName = call_runtime.isTeluguScriptExtensionsName;
const isTeluguScriptName = call_runtime.isTeluguScriptName;
const isThaanaScriptExtensionsName = call_runtime.isThaanaScriptExtensionsName;
const isThaanaScriptName = call_runtime.isThaanaScriptName;
const isThaiScriptExtensionsName = call_runtime.isThaiScriptExtensionsName;
const isThaiScriptName = call_runtime.isThaiScriptName;
const isTibetanScriptExtensionsName = call_runtime.isTibetanScriptExtensionsName;
const isTibetanScriptName = call_runtime.isTibetanScriptName;
const isTifinaghScriptExtensionsName = call_runtime.isTifinaghScriptExtensionsName;
const isTifinaghScriptName = call_runtime.isTifinaghScriptName;
const isTirhutaScriptExtensionsName = call_runtime.isTirhutaScriptExtensionsName;
const isTirhutaScriptName = call_runtime.isTirhutaScriptName;
const isTodhriScriptExtensionsName = call_runtime.isTodhriScriptExtensionsName;
const isTodhriScriptName = call_runtime.isTodhriScriptName;
const isTolongSikiScriptExtensionsName = call_runtime.isTolongSikiScriptExtensionsName;
const isTolongSikiScriptName = call_runtime.isTolongSikiScriptName;
const isTotoScriptExtensionsName = call_runtime.isTotoScriptExtensionsName;
const isTotoScriptName = call_runtime.isTotoScriptName;
const isTuluTigalariScriptExtensionsName = call_runtime.isTuluTigalariScriptExtensionsName;
const isTuluTigalariScriptName = call_runtime.isTuluTigalariScriptName;
const isTypedArrayPrototypeMethod = array_ops.isTypedArrayPrototypeMethod;
const isUgariticScriptExtensionsName = call_runtime.isUgariticScriptExtensionsName;
const isUgariticScriptName = call_runtime.isUgariticScriptName;
const isUnassignedGeneralCategoryName = call_runtime.isUnassignedGeneralCategoryName;
const isUppercaseLetterGeneralCategoryName = call_runtime.isUppercaseLetterGeneralCategoryName;
const isVaiScriptExtensionsName = call_runtime.isVaiScriptExtensionsName;
const isVaiScriptName = call_runtime.isVaiScriptName;
const isVithkuqiScriptExtensionsName = call_runtime.isVithkuqiScriptExtensionsName;
const isVithkuqiScriptName = call_runtime.isVithkuqiScriptName;
const isWanchoScriptExtensionsName = call_runtime.isWanchoScriptExtensionsName;
const isWanchoScriptName = call_runtime.isWanchoScriptName;
const isWarangCitiScriptExtensionsName = call_runtime.isWarangCitiScriptExtensionsName;
const isWarangCitiScriptName = call_runtime.isWarangCitiScriptName;
const isXidContinueName = call_runtime.isXidContinueName;
const isYezidiScriptExtensionsName = call_runtime.isYezidiScriptExtensionsName;
const isYezidiScriptName = call_runtime.isYezidiScriptName;
const isYiScriptExtensionsName = call_runtime.isYiScriptExtensionsName;
const isYiScriptName = call_runtime.isYiScriptName;
const isZanabazarSquareScriptExtensionsName = call_runtime.isZanabazarSquareScriptExtensionsName;
const isZanabazarSquareScriptName = call_runtime.isZanabazarSquareScriptName;
const lengthIndexValue = array_ops.lengthIndexValue;
const objectFromValue = object_ops.objectFromValue;
const ownDataOrAutoInitPropertyValue = object_ops.ownDataOrAutoInitPropertyValue;
const primitiveObjectForAccess = object_ops.primitiveObjectForAccess;
const propertyAtomFromLengthIndex = object_ops.propertyAtomFromLengthIndex;
const propertyEscapePattern = object_ops.propertyEscapePattern;
const proxyTargetIsCallableObject = object_ops.proxyTargetIsCallableObject;
const qjsArrayLastIndexSparseLarge = array_ops.qjsArrayLastIndexSparseLarge;
const qjsIteratorPrototype = object_ops.qjsIteratorPrototype;
const qjsRegExpConstructCall = regexp_fastpath.qjsRegExpConstructCall;
const qjsRegExpExecGeneric = regexp_fastpath.qjsRegExpExecGeneric;
const qjsRegExpSpeciesConstructor = regexp_fastpath.qjsRegExpSpeciesConstructor;
const readUnicodePropertyClassEscape = object_ops.readUnicodePropertyClassEscape;
const regExpConstructorFromGlobal = regexp_fastpath.regExpConstructorFromGlobal;
const regExpExecPropertyIsDefault = object_ops.regExpExecPropertyIsDefault;
const regExpFlagsAreFullUnicode = regexp_fastpath.regExpFlagsAreFullUnicode;
const regexpInternalFlagsContain = regexp_fastpath.regexpInternalFlagsContain;
const setRegExpLastIndexZero = regexp_fastpath.setRegExpLastIndexZero;
const setValueProperty = object_ops.setValueProperty;
const setValuePropertyStrict = object_ops.setValuePropertyStrict;

const throwRangeErrorMessage = exception_ops.throwRangeErrorMessage;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const toLengthIndex = coercion_ops.toLengthIndex;
const toLengthNumber = coercion_ops.toLengthNumber;
const toNumberLikeArgument = builtin_glue.toNumberLikeArgument;
const toPrimitiveForNumber = coercion_ops.toPrimitiveForNumber;
const toUint16CodeUnit = coercion_ops.toUint16CodeUnit;
const toUint32Number = coercion_ops.toUint32Number;
const uint32NumberValue = coercion_ops.uint32NumberValue;
const unicodePropertyOnlyClassBody = object_ops.unicodePropertyOnlyClassBody;
const unicodePropertyOnlyClassSource = object_ops.unicodePropertyOnlyClassSource;
const updateRegExpLegacyStaticsNoCaptures = regexp_fastpath.updateRegExpLegacyStaticsNoCaptures;
const valueTruthy = coercion_ops.valueTruthy;
const valuesStrictEqual = value_ops.valuesStrictEqual;

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

// Construct records the string ops route through (Phase 6b-3 STEP 4) instead
// of naming `builtins.{string,regexp}.constructWithPrototype` directly: the
// observable coercion stays here and the coerced primitives + resolved
// prototype are threaded to the record. Both construct branches read only
// `args`/`new_target`, so no constructor function object is threaded.
const string_construct_ref = core.function.NativeBuiltinRef{
    .domain = .string,
    .id = @intFromEnum(method_ids.string.ConstructorMethod.call),
};
const regexp_construct_ref = core.function.NativeBuiltinRef{
    .domain = .regexp,
    .id = @intFromEnum(method_ids.regexp.ConstructorMethod.construct),
};

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
    return (try builtin_dispatch.callConstructRecord(ctx, output, global, &.{}, null, string_construct_ref, prototype, &.{string_value}, caller_function, caller_frame)) orelse error.TypeError;
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

pub fn buildErrorStackStringValue(ctx: *core.JSContext, global: *core.Object, skip_name: ?[]const u8) !core.JSValue {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);

    const limit = errorStackTraceLimit(ctx.runtime, global);
    if (limit == 0) return value_ops.createStringValue(ctx.runtime, "");

    const frames = try ctx.snapshotBacktraceFrames();
    defer ctx.freeBacktraceFrameSnapshot(frames);
    var idx = frames.len;
    var emitted: usize = 0;
    var skipping = skip_name != null;
    while (idx > 0) {
        idx -= 1;
        _ = exception_ops.resolveBacktraceFunctionName(ctx, &frames[idx]);
        if (skipping) {
            if (backtraceFunctionNameEql(ctx, frames[idx], skip_name.?)) skipping = false;
            continue;
        }
        if (emitted >= limit) break;
        const entry = frames[idx];
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

    const current_length: usize = if (sites.flags.is_array) @intCast(sites.arrayLength()) else 0;
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
        try appendUtf16CodePoint(ctx.runtime, &units, code_point);
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
    if (!array.flags.is_array) return error.TypeError;
    if (try qjsStringFromCodePointDenseArray(ctx.runtime, array)) |value| return value;
    var units = std.ArrayList(u16).empty;
    defer units.deinit(ctx.runtime.memory.allocator);
    var index: u32 = 0;
    while (index < array.arrayLength()) : (index += 1) {
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
        try appendUtf16CodePoint(ctx.runtime, &units, code_point);
    }
    return (try core.string.String.createUtf16(ctx.runtime, units.items)).value();
}

pub fn qjsStringFromCodePointDenseArray(rt: *core.JSRuntime, array: *core.Object) !?core.JSValue {
    if (array.arrayElementStorageMode() != .dense) return null;
    const length: usize = @intCast(array.arrayLength());
    if (array.arrayElements().len >= length) {
        if (length == 0) return (try core.string.String.createAscii(rt, "")).value();
        const max_units = try std.math.mul(usize, length, 2);
        const units = try rt.memory.alloc(u16, max_units);
        var consumed_units = false;
        defer if (!consumed_units) rt.memory.free(u16, units);

        var unit_count: usize = 0;
        var index: usize = 0;
        while (index < length) : (index += 1) {
            const value = array.arrayElements()[index];
            const number = value_ops.numberValue(value) orelse return null;
            const code_point = validStringCodePoint(number) orelse return error.RangeError;
            if (code_point <= 0xffff) {
                units[unit_count] = @intCast(code_point);
                unit_count += 1;
            } else {
                const pair = unicode_lib.surrogatePairFromCodePoint(@intCast(code_point));
                units[unit_count] = pair.high;
                units[unit_count + 1] = pair.low;
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
    for (array.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted) continue;
        const index = core.array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) orelse continue;
        if (index >= array.arrayLength()) continue;
        if (prop_flags.isAccessor()) return null;
        // Array elements never carry `auto_init` placeholders -- those only
        // appear for builtin method tables installed via
        // `defineAutoInitProperty`; only the `.data` kind is valid here.
        const value = array.asDataAt(property_index) orelse return null;
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
        const pair = unicode_lib.surrogatePairFromCodePoint(@intCast(code_point));
        units.appendAssumeCapacity(pair.high);
        units.appendAssumeCapacity(pair.low);
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

/// Like `qjsRegExpAutoInitBuiltinMatches` but for a lazily-installed native
/// accessor (the RegExp.prototype flag getters live as `.native_accessor`
/// auto-init descriptors whose getter native-builtin id is `native_builtin_id`).
pub fn qjsRegExpAutoInitAccessorBuiltinMatches(info: core.property.AutoInit, expected_id: u32) bool {
    if (info.kind != .native_accessor) return false;
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

pub fn latin1StringSlice(value: core.JSValue) ?[]const u8 {
    const string_object = value.asStringBody() orelse return null;
    return switch (string_object.resolveData()) {
        .latin1 => |bytes| bytes,
        .utf16 => null,
    };
}

pub fn regexpInternalStringValue(rt: *core.JSRuntime, object: *core.Object, source: bool) !core.JSValue {
    if (source) {
        return (object.regexpSource() orelse return error.TypeError).dup();
    }
    return regexp_adapter.flagsStringValueFromBytecode(rt, object.regexpCompiledBytecode());
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
    const regexp_args = [_]core.JSValue{ regexp, flags };
    const matcher = (try builtin_dispatch.callConstructRecord(ctx, output, global, &.{}, null, regexp_construct_ref, constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"), &regexp_args, caller_function, caller_frame)) orelse return error.TypeError;
    defer matcher.free(ctx.runtime);
    const match_all = try getValueProperty(ctx, output, global, matcher, match_all_atom, caller_function, caller_frame);
    defer match_all.free(ctx.runtime);
    if (match_all.isUndefined() or match_all.isNull()) return error.TypeError;
    return callValueOrBytecode(ctx, output, global, matcher, match_all, &.{string_value}, caller_function, caller_frame);
}

pub fn qjsRegExpStringIteratorPrototype(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    const proto = try qjsIteratorPrototype(rt, global, "RegExp String Iterator");
    errdefer core.Object.destroyFromHeader(rt, &proto.header);
    const next = try core.function.nativeFunction(rt, "next", 0);
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
    if (!isHighSurrogateUnit(first)) return index + 1;
    const second = units[index + 1];
    return if (isLowSurrogateUnit(second)) index + 2 else index + 1;
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
    if (!previous.sameValue(core.JSValue.int32(0))) {
        try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    }

    const result = try qjsRegExpExecGeneric(ctx, output, global, rx, string_value, caller_function, caller_frame);
    defer result.free(ctx.runtime);

    const current = try getValueProperty(ctx, output, global, rx, core.atom.ids.lastIndex, caller_function, caller_frame);
    defer current.free(ctx.runtime);
    if (!current.sameValue(previous)) {
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

    // Standard-regexp fast path (QuickJS js_is_standard_regexp -> js_regexp_replace),
    // probed BEFORE observing the flags getter -- exactly like QuickJS. The guard
    // is fully side-effect-free (never invokes exec/flags/global/unicode), so a
    // non-standard regexp falls through to the generic path which observes those
    // getters in spec order. The fast path drives matching on the compiled
    // bytecode with a single reused capture buffer and no per-match array object.
    if (!functional_replace) {
        if (objectFromValue(rx)) |rx_object| {
            if (object_ops.regExpIsStandard(ctx.runtime, rx_object)) {
                if (try qjsRegExpReplaceFast(ctx, output, global, rx, string_value, replacement_string, caller_function, caller_frame)) |res| {
                    return res;
                }
            }
        }
    }

    const flags_string = try getRegExpFlagsStringForReplace(ctx, output, global, rx, caller_function, caller_frame);
    defer flags_string.free(ctx.runtime);
    const is_global = try qjsStringValueContainsByte(ctx.runtime, flags_string, 'g');
    const full_unicode = try regExpFlagsAreFullUnicode(ctx.runtime, flags_string);
    if (is_global) {
        try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
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

    const replacement_is_empty = !functional_replace and (try stringLengthIndex(ctx.runtime, replacement_string) == 0);
    const replacement_is_literal = !functional_replace and !replacement_is_empty and !stringValueContainsUnitByte(replacement_string, '$');

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
        else if (replacement_is_empty and match.groups.isUndefined())
            core.JSValue.undefinedValue()
        else if (replacement_is_literal and match.groups.isUndefined())
            replacement_string.dup()
        else
            try getSubstitutionString(ctx, output, global, match, string_value, replacement_string, caller_function, caller_frame);
        defer replacement.free(ctx.runtime);
        if (!replacement_is_empty) try appendStringValueUnits(ctx.runtime, &out, replacement);
        next_source_position = @min(source_units.items.len, position + matched_len);
    }
    try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[next_source_position..]);
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

// Faithful port of QuickJS `js_regexp_replace` (quickjs.c) -- the "simple cases"
// fast path taken by `js_regexp_Symbol_replace` when the replacement is a plain
// string (non-functional) and the regexp is standard (default `exec`). Drives
// matching directly on the compiled bytecode + a single reused capture buffer,
// substituting `$` patterns straight from the source units. NO per-match JS
// array object, NO property reads, NO per-match allocation -- this is the whole
// reason QuickJS is ~18x faster here. Returns null to bail to the generic
// driver when preconditions fail (non-RegExp receiver, missing bytecode,
// coercible lastIndex required, or named groups present).
pub fn qjsRegExpReplaceFast(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    replacement_string: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const rx_object = objectFromValue(rx) orelse return null;
    if (rx_object.class_id != core.class.ids.regexp) return null;
    if (!regexp_fastpath.regExpLastIndexCanSkipCoercion(rx_object)) return null;
    const cached_bytecode = rx_object.regexpCompiledBytecode();
    if (cached_bytecode.len == 0) return null;
    const compiled = regexp_adapter.Compiled{ .bytecode = @constCast(cached_bytecode) };
    const bits = compiled.flagBits();
    // QuickJS bails on group names (the generic driver handles `$<name>`).
    if ((bits & regexp_adapter.flag_bits.named_groups) != 0) return null;
    // Read flags straight from the compiled bytecode -- like QuickJS's
    // js_regexp_replace -- instead of observing the (potentially overridden)
    // flags getter. Safe because the caller already confirmed `exec` is default.
    const is_global = (bits & regexp_adapter.flag_bits.global) != 0;
    const is_sticky = (bits & regexp_adapter.flag_bits.sticky) != 0;
    const full_unicode = (bits & (regexp_adapter.flag_bits.unicode | regexp_adapter.flag_bits.unicode_sets)) != 0;
    // QuickJS resets lastIndex to 0 up front for global regexps.
    if (is_global) try setRegExpLastIndexZero(ctx.runtime, rx_object);

    var source = std.ArrayList(u16).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &source, string_value);
    var replacement = std.ArrayList(u16).empty;
    defer replacement.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &replacement, replacement_string);

    const alloc_count = compiled.allocCount();
    const capture_count = compiled.captureCount();
    var inline_capture_slots: [regexp_adapter.small_exec_slots]usize = undefined;
    var heap_capture_slots: []usize = &.{};
    defer if (heap_capture_slots.len != 0) ctx.runtime.memory.allocator.free(heap_capture_slots);
    const capture = if (alloc_count <= inline_capture_slots.len)
        inline_capture_slots[0..alloc_count]
    else capture: {
        heap_capture_slots = try ctx.runtime.memory.allocator.alloc(usize, alloc_count);
        break :capture heap_capture_slots;
    };

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);

    // lastIndex: the caller already reset it to 0 for global regexps. Sticky
    // (non-global) reads it; otherwise matching starts at 0 (qjs js_regexp_replace).
    var last_index: usize = 0;
    if (!is_global and is_sticky) {
        last_index = regexp_fastpath.regexpLastIndex(ctx.runtime, rx_object);
    }
    var next_src: usize = 0;
    while (true) {
        if (last_index > source.items.len) {
            if (is_global or is_sticky) try setRegExpLastIndexZero(ctx.runtime, rx_object);
            break;
        }
        const result = regexp_adapter.execCaptureSlotsOnStringFromIndex(ctx.runtime, compiled, string_value, last_index, capture) catch |err| switch (err) {
            error.BytecodeCorrupt, error.Timeout => return null,
            else => return err,
        };
        if (result != .match) {
            if (is_global or is_sticky) try setRegExpLastIndexZero(ctx.runtime, rx_object);
            break;
        }
        const match_start = regexp_adapter.captureSlotValue(capture[0]) orelse 0;
        const match_end = regexp_adapter.captureSlotValue(capture[1]) orelse match_start;
        if (next_src < match_start) try out.appendSlice(ctx.runtime.memory.allocator, source.items[next_src..match_start]);
        if (replacement.items.len != 0) {
            try appendRegExpSubstitutionFromSlots(ctx.runtime, &out, source.items, match_start, match_end, capture, capture_count, replacement.items);
        }
        next_src = match_end;
        if (!is_global) {
            if (is_sticky) {
                const next_value = if (match_end <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(match_end))
                else
                    core.JSValue.float64(@floatFromInt(match_end));
                try regexp_fastpath.setRegExpLastIndexStrict(ctx, output, global, rx, rx_object, next_value, caller_function, caller_frame);
            }
            break;
        }
        last_index = if (match_end == match_start)
            advanceStringIndexUnits(source.items, match_end, full_unicode)
        else
            match_end;
    }
    if (next_src < source.items.len) try out.appendSlice(ctx.runtime.memory.allocator, source.items[next_src..]);
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

const ReplaceLiteralMatch = struct {
    result: core.JSValue,
    matched: core.JSValue,
    index: usize,
};

pub fn qjsRegExpSymbolReplaceLiteral(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    replacement_string: core.JSValue,
    is_global: bool,
    full_unicode: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var source_units = std.ArrayList(u16).empty;
    defer source_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &source_units, string_value);

    var replacement_units = std.ArrayList(u16).empty;
    defer replacement_units.deinit(ctx.runtime.memory.allocator);
    try appendStringValueUnits(ctx.runtime, &replacement_units, replacement_string);

    var out = std.ArrayList(u16).empty;
    defer out.deinit(ctx.runtime.memory.allocator);
    var next_source_position: usize = 0;
    var matched_any = false;

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

        const match = try captureReplaceLiteralMatch(ctx, output, global, result, string_value, caller_function, caller_frame);
        defer {
            match.result.free(ctx.runtime);
            match.matched.free(ctx.runtime);
        }

        matched_any = true;
        const matched_len = try stringLengthIndex(ctx.runtime, match.matched);
        const position = @min(match.index, source_units.items.len);
        if (position >= next_source_position) {
            try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[next_source_position..position]);
            try out.appendSlice(ctx.runtime.memory.allocator, replacement_units.items);
            next_source_position = @min(source_units.items.len, position + matched_len);
        }

        if (!is_global) break;
        if (isEmptyStringValue(ctx.runtime, match.matched)) {
            const last_index = try getValueProperty(ctx, output, global, rx, core.atom.ids.lastIndex, caller_function, caller_frame);
            defer last_index.free(ctx.runtime);
            const next = try advanceStringIndexNumber(ctx, output, global, string_value, last_index, full_unicode);
            try setValuePropertyStrict(ctx, output, global, rx, core.atom.ids.lastIndex, next, caller_function, caller_frame);
        }
    }

    if (!matched_any) return string_value.dup();
    try out.appendSlice(ctx.runtime.memory.allocator, source_units.items[next_source_position..]);
    return (try core.string.String.createUtf16(ctx.runtime, out.items)).value();
}

pub fn captureReplaceLiteralMatch(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    result: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !ReplaceLiteralMatch {
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
    return .{ .result = result, .matched = matched, .index = index };
}

pub fn appendStringValueUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), value: core.JSValue) !void {
    const string_object = value.asStringBody() orelse {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try value_ops.appendRawString(rt, &bytes, value);
        for (bytes.items) |byte| try out.append(rt.memory.allocator, byte);
        return;
    };
    try string_object.ensureFlat(rt);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| for (bytes) |byte| try out.append(rt.memory.allocator, byte),
        .utf16 => |units| try out.appendSlice(rt.memory.allocator, units),
    }
}

pub fn stringValueContainsUnitByte(value: core.JSValue, needle: u8) bool {
    const string_object = value.asStringBody() orelse return false;
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
    const string_object = value.asStringBody() orelse return false;
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

// Parse a `$n`/`$nn` capture reference at `replacement[index+1..]` against a
// match with `capture_count` slots (group 0 included). Mirrors
// `replacementCaptureUnits` but yields the one-based group number + consumed
// digit count instead of a materialized JSValue. `null` => not a valid
// reference (emit a literal `$`).
const SlotCaptureRef = struct { group: usize, consumed: usize };
fn parseSlotCaptureRef(replacement: []const u16, index: usize, capture_count: usize) ?SlotCaptureRef {
    if (capture_count == 0) return null;
    const max_group = capture_count - 1; // valid groups are 1..max_group
    if (max_group == 0) return null;
    const first = replacement[index + 1];
    if (!isAsciiDigitUnit(first)) return null;
    if (first == '0') {
        if (index + 2 >= replacement.len or !isAsciiDigitUnit(replacement[index + 2])) return null;
        const two: usize = @intCast(replacement[index + 2] - '0');
        if (two == 0 or two > max_group) return null;
        return .{ .group = two, .consumed = 2 };
    }
    var group: usize = @intCast(first - '0');
    var consumed: usize = 1;
    if (index + 2 < replacement.len and isAsciiDigitUnit(replacement[index + 2])) {
        const two = group * 10 + @as(usize, @intCast(replacement[index + 2] - '0'));
        if (two >= 1 and two <= max_group) {
            group = two;
            consumed = 2;
        }
    }
    if (group == 0 or group > max_group) return null;
    return .{ .group = group, .consumed = consumed };
}

// Faithful port of QuickJS `js_string_GetSubstitution` operating directly on the
// raw capture-slot buffer (no per-match array object). `$&`/`` $` ``/`$'`/`$$`
// and `$n`/`$nn` are all slices of the source units; an unmatched group expands
// to empty. Group-name (`$<name>`) substitution is intentionally NOT handled
// here -- the fast path bails to the generic driver when the pattern has named
// groups, exactly as QuickJS does.
fn appendRegExpSubstitutionFromSlots(
    rt: *core.JSRuntime,
    out: *std.ArrayList(u16),
    source: []const u16,
    match_start: usize,
    match_end: usize,
    capture: []const usize,
    capture_count: usize,
    replacement: []const u16,
) !void {
    const alloc = rt.memory.allocator;
    var index: usize = 0;
    while (index < replacement.len) : (index += 1) {
        const unit = replacement[index];
        if (unit != '$' or index + 1 >= replacement.len) {
            try out.append(alloc, unit);
            continue;
        }
        switch (replacement[index + 1]) {
            '$' => {
                try out.append(alloc, '$');
                index += 1;
            },
            '&' => {
                try out.appendSlice(alloc, source[match_start..match_end]);
                index += 1;
            },
            '`' => {
                try out.appendSlice(alloc, source[0..match_start]);
                index += 1;
            },
            '\'' => {
                try out.appendSlice(alloc, source[match_end..]);
                index += 1;
            },
            '0'...'9' => {
                if (parseSlotCaptureRef(replacement, index, capture_count)) |ref| {
                    index += ref.consumed;
                    if (regexp_adapter.captureSlotValue(capture[2 * ref.group])) |cstart| {
                        const cend = regexp_adapter.captureSlotValue(capture[2 * ref.group + 1]) orelse cstart;
                        try out.appendSlice(alloc, source[cstart..cend]);
                    }
                } else {
                    try out.append(alloc, '$');
                }
            },
            else => try out.append(alloc, '$'),
        }
    }
}

pub fn stringLengthIndex(rt: *core.JSRuntime, string_value: core.JSValue) !usize {
    const string_object = string_value.asStringBody() orelse return 0;
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
    const string_object = string_value.asStringBody() orelse return value_ops.numberToValue(index_number + 1);
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
    const string_value = value.asStringBody() orelse return null;
    if (string_value.atom_id == core.string.String.no_atom_id) return null;
    return string_value.atom_id;
}

pub fn nativeFunctionMatcherUnicodeClassAsciiResult(source: []const u8, flags: []const u8, string_value: core.JSValue, start_index: usize) ?bool {
    if (flags.len != 0 or start_index != 0) return null;
    const is_id_start = std.mem.startsWith(u8, source, "(?:[A-Za-z");
    const is_id_continue = std.mem.startsWith(u8, source, "(?:[0-9A-Z_a-z");
    if (!is_id_start and !is_id_continue) return null;
    const string_object = string_value.asStringBody() orelse return null;
    if (string_object.len() != 1) return null;
    const unit = string_object.codeUnitAt(0);
    if (unit > 0x7f) return null;
    const byte: u8 = @intCast(unit);
    if (unicode_lib.isAsciiAlphaByte(byte)) return true;
    if (is_id_continue and unicode_lib.isAsciiDigitByte(byte)) return true;
    if (is_id_continue and byte == '_') return true;
    return false;
}

pub fn findPropertyEscapeMatch(source: []const u8, string_value: core.JSValue, start_index: usize, sticky: bool) ?RegExpMatch {
    const parsed = propertyEscapePattern(source) orelse return null;
    const string_object = string_value.asStringBody() orelse return null;
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

pub fn findUnicodePropertyOnlyClassMatch(source: []const u8, string_value: core.JSValue, start_index: usize, sticky: bool) ?RegExpMatch {
    if (!unicodePropertyOnlyClassSource(source)) return null;
    const string_object = string_value.asStringBody() orelse return null;
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

/// Route a reused String method *body* through the record table's
/// func-object-free arm. `decoded_method_id` is the legacy selector the builtin
/// string bodies switch on; it is re-encoded to its `PrototypeMethod` record id
/// so the dispatch lands on `builtins/string.zig` `stringCall`, whose
/// `func_obj == null` arm runs the pure `methodCall` (or, for `charAt`,
/// `charAtValue`) body directly. `string_value` is the resolved receiver and
/// `args` are already coerced. This replaces the former direct
/// `builtins.string.methodCall`/`charAtValue` calls so exec carries no
/// compile-time String body knowledge.
pub fn callStringBody(
    ctx: *core.JSContext,
    string_value: core.JSValue,
    decoded_method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const native_ref = core.function.NativeBuiltinRef{ .domain = .string, .id = string_id_lookup.encodePrototypeMethodId(decoded_method_id) orelse return error.TypeError };
    return (try builtin_dispatch.callInternalRecord(ctx, null, null, &.{}, null, string_value, native_ref, args, null, null)) orelse error.TypeError;
}

/// Route `String.prototype.charAt` (decoded id 0, the `charAtValue` body)
/// through the table. The receiver is `string_value` and the single index is
/// forwarded as `args[0]`.
pub fn callStringCharAtBody(
    ctx: *core.JSContext,
    string_value: core.JSValue,
    index_value: core.JSValue,
) !core.JSValue {
    return callStringBody(ctx, string_value, 0, &.{index_value});
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
    return callStringBody(ctx, string_value, method_id, &.{});
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
    if (method_id == string_id_lookup.legacy_split_method_id) {
        return qjsStringSplit(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_search_method_id) {
        return qjsStringSearch(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_match_method_id) {
        return qjsStringMatch(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_replace_all_method_id) {
        return qjsStringReplaceAll(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_match_all_method_id) {
        return qjsStringMatchAll(ctx, output, global, this_value, args, caller_function, caller_frame);
    }
    // Pad / Html / Normalize / LocaleCompare / NumericArgs bodies live in this
    // file (Phase 6b-3 STEP 3B moved them back from `builtins/string.zig`): they
    // are exec-only, reachable solely through this dispatcher. The RegExp-coupled
    // bodies (search/match/split/replaceAll/matchAll and
    // `qjsStringSearchPositionMethod`, which observes RegExp via
    // `isRegExpForStringSearch`) and the BOTH bodies (concat) also stay in exec.
    if (method_id == 34 or method_id == 35) {
        return qjsStringPad(ctx, output, global, this_value, method_id, args, caller_function, caller_frame);
    }
    if (method_id == 11 or method_id == 12 or method_id == 13 or method_id == 14 or method_id == 15 or
        method_id == 16 or method_id == 17 or method_id == 18 or method_id == 19 or method_id == 20 or
        method_id == 23 or method_id == 24 or method_id == 26)
    {
        return qjsStringHtmlMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame);
    }
    if (method_id == string_id_lookup.legacy_normalize_method_id) {
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
    return callStringBody(ctx, string_value, method_id, args) catch |err| switch (err) {
        error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid repeat count"),
        else => err,
    };
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
    return unicode_lib.appendUtf16CodePoint(rt.memory.allocator, out, @intCast(code_point));
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

    return callStringBody(ctx, string_value, method_id, coerced[0..count]);
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
    try builtin_glue.defineNativeDataMethodWithNativeId(ctx.runtime, object, "next", 0, core.function.nativeBuiltinId(.string, @intFromEnum(method_ids.string.PrototypeMethod.iterator_next)));

    const iterator_method = try core.function.nativeFunction(ctx.runtime, "[Symbol.iterator]", 0);
    defer iterator_method.free(ctx.runtime);
    const iterator_function = property_ops.expectObject(iterator_method) catch return error.TypeError;
    if (!iterator_function.addIteratorIdentityFunction(ctx.runtime)) return error.TypeError;
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
    const result = try callStringBody(ctx, string_value, string_id_lookup.legacy_split_method_id, args);
    errdefer result.free(ctx.runtime);
    if (objectFromValue(result)) |object| {
        if (object.flags.is_array and object.getPrototype() == null) {
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

    var compiled = regexp_adapter.compile(rt.memory.allocator, source.items, split_flags.items) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return null,
        else => |other| return other,
    };
    defer compiled.deinit(rt.memory.allocator);

    const input_len = try stringLengthIndex(rt, string_value);

    if (input_len == 0) {
        const status = regexp_adapter.execOnStringFromIndex(rt, compiled, string_value, 0) catch |err| switch (err) {
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
        const status = regexp_adapter.execOnStringFromIndex(rt, compiled, string_value, pos) catch |err| switch (err) {
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

    var compiled = regexp_adapter.compile(rt.memory.allocator, source.items, flags.items) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return null,
        else => |other| return other,
    };
    defer compiled.deinit(rt.memory.allocator);

    const input_len = try stringLengthIndex(rt, string_value);
    const status = regexp_adapter.execOnStringFromIndex(rt, compiled, string_value, 0) catch |err| switch (err) {
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
        var compiled = regexp_adapter.compile(rt.memory.allocator, source.items, flags.items) catch |err| switch (err) {
            error.InvalidPattern, error.Unsupported => return null,
            else => |other| return other,
        };
        defer compiled.deinit(rt.memory.allocator);
        const input_len = try stringLengthIndex(rt, string_value);
        const status = regexp_adapter.execOnStringFromIndex(rt, compiled, string_value, 0) catch |err| switch (err) {
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
                return try createRegExpMatchArrayFromValue(rt, global, string_value, &found, has_indices);
            },
            .no_match, .out_of_range, .not_available => return null,
        }
    }

    // Global: iterate through all matches
    var compiled = regexp_adapter.compile(rt.memory.allocator, source.items, flags.items) catch |err| switch (err) {
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
        const status = regexp_adapter.execOnStringFromIndex(rt, compiled, string_value, search_pos) catch |err| switch (err) {
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

pub fn advanceStringIndexStringValue(string_value: core.string.String, index: usize, unicode: bool) usize {
    if (!unicode or index + 1 >= string_value.len()) return index + 1;
    const first = string_value.codeUnitAt(index);
    const second = string_value.codeUnitAt(index + 1);
    return index + if (isHighSurrogateUnit(first) and isLowSurrogateUnit(second)) @as(usize, 2) else 1;
}

pub fn findStringUnitMatch(value: core.JSValue, unit: u16, start: usize) ?usize {
    const string_value = value.asStringBody() orelse return null;
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
    return unicode_lib.codePointFromSurrogatePair(high, low);
}

pub fn surrogatePairFromCodePoint(code_point: u21) unicode_lib.SurrogatePair {
    return unicode_lib.surrogatePairFromCodePoint(code_point);
}

pub fn findUnicodeFoldClassMatch(value: core.JSValue, unit: u16, start: usize) ?usize {
    const string_value = value.asStringBody() orelse return null;
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
    const string_value = value.asStringBody() orelse return false;
    return switch (string_value.resolveData()) {
        .latin1 => false,
        .utf16 => |units| index < units.len and isHighSurrogateUnit(units[index]),
    };
}

pub fn singleDotAnchoredMatches(rt: *core.JSRuntime, string_value: core.JSValue, flags: []const u8) !bool {
    const string_object = string_value.asStringBody() orelse return false;
    try string_object.ensureFlat(rt);
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
    const string_object = string_value.asStringBody() orelse return false;
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
    const string_object = string_value.asStringBody() orelse return false;
    switch (string_object.resolveData()) {
        .latin1 => |bytes| return bytes.len == 1 and !isEcmaWhitespaceOrLineTerminator(bytes[0]),
        .utf16 => |units| {
            if (unicode and units.len == 2 and isHighSurrogateUnit(units[0]) and isLowSurrogateUnit(units[1])) return true;
            return units.len == 1 and !isEcmaWhitespaceOrLineTerminator(units[0]);
        },
    }
}

pub fn anchoredComplementClassMatches(source: []const u8, string_value: core.JSValue) bool {
    const string_object = string_value.asStringBody() orelse return false;
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
    const string_object = string_value.asStringBody() orelse return false;
    const name = anchoredBinaryPropertyName(source) orelse return false;
    const positive = std.mem.startsWith(u8, source, "^\\p{");
    return anchoredCodePointPredicateMatches(string_object, positive, name);
}

pub fn binaryPropertyCodePointMatches(name: []const u8, code_point: u21) bool {
    return regexp_properties.isUnicodePropertyMatches(code_point, name);
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
                if (regexp_properties.isUnicodePropertyMatches(byte, name) != positive) return false;
            }
            return true;
        },
        .utf16 => |units| {
            if (units.len == 0) return false;
            var index: usize = 0;
            while (index < units.len) {
                if (regexp_properties.isUnicodePropertyMatches(readUtf16CodePoint(units, &index), name) != positive) return false;
            }
            return true;
        },
    }
}

pub fn readUtf16CodePoint(units: []const u16, index: *usize) u21 {
    const high = units[index.*];
    if (isHighSurrogateUnit(high) and index.* + 1 < units.len) {
        const low = units[index.* + 1];
        if (isLowSurrogateUnit(low)) {
            index.* += 2;
            return unicode_lib.codePointFromSurrogatePair(high, low);
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

pub const LazyRegExpLegacyCapture = struct {
    start: usize,
    len: usize,
};

const lazy_legacy_capture_len_bits: u6 = 20;
const lazy_legacy_capture_len_limit: usize = @as(usize, 1) << lazy_legacy_capture_len_bits;
const lazy_legacy_capture_len_mask: u64 = lazy_legacy_capture_len_limit - 1;
const lazy_legacy_capture_start_limit: usize = @as(usize, 1) << (47 - lazy_legacy_capture_len_bits);
const lazy_legacy_capture_payload_limit: i64 = @as(i64, 1) << 47;

pub fn encodeRegExpLegacyCaptureSlice(start: usize, len: usize) ?core.JSValue {
    if (start >= lazy_legacy_capture_start_limit or len >= lazy_legacy_capture_len_limit) return null;
    const payload = (@as(u64, @intCast(start)) << lazy_legacy_capture_len_bits) | @as(u64, @intCast(len));
    return core.JSValue.shortBigInt(@intCast(payload));
}

pub fn decodeRegExpLegacyCaptureSlice(value: core.JSValue) ?LazyRegExpLegacyCapture {
    const payload_i64 = value.asShortBigInt() orelse return null;
    if (payload_i64 < 0 or payload_i64 >= lazy_legacy_capture_payload_limit) return null;
    const payload: u64 = @intCast(payload_i64);
    return .{
        .start = @intCast(payload >> lazy_legacy_capture_len_bits),
        .len = @intCast(payload & lazy_legacy_capture_len_mask),
    };
}

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

pub fn regExpMatchHasNamedCaptures(found: *const RegExpMatch) bool {
    for (found.captures[0..found.capture_count]) |capture| {
        if (capture.name != null) return true;
    }
    return false;
}

pub fn createRegExpMatchArray(rt: *core.JSRuntime, global: *core.Object, input_bytes: []const u8, found: *const RegExpMatch, has_indices: bool) !core.JSValue {
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

// Build (once per realm) a throwaway template array carrying the
// index/input/groups named-property shape, and keep it pinned in the realm
// cache. QuickJS holds an equivalent `regexp_result_shape` permanently
// (quickjs.c:49297); the permanent reference keeps the shape's transition chain
// hash-consed so every match array reuses it instead of cloning + rehashing a
// fresh shape that is then destroyed when the (immediately discarded) array is
// freed. Pure performance: missing/failing warm-up just falls back to the
// per-array clone path.
fn ensureRegExpResultShapeWarm(rt: *core.JSRuntime, global: *core.Object) void {
    const slot = global.cachedRealmValueSlot(rt, .regexp_match_result_template) catch return;
    if (slot.* != null) return;
    const template = core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global)) catch return;
    template.defineRegExpMatchMetadataPropertiesAssumingNew(rt, 0, core.JSValue.undefinedValue(), core.JSValue.undefinedValue()) catch {
        core.Object.destroyFromHeader(rt, &template.header);
        return;
    };
    global.setOptionalValueSlot(rt, slot, template.value()) catch {
        core.Object.destroyFromHeader(rt, &template.header);
        return;
    };
}

pub fn createRegExpMatchArrayFromValue(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, has_indices: bool) !core.JSValue {
    ensureRegExpResultShapeWarm(rt, global);
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &out.header);

    const matched = try stringSliceValue(rt, input_value, found.index, found.len);
    defer matched.free(rt);

    try initRegExpMatchArrayDenseElementsFromValue(rt, out, input_value, found, matched);

    try updateRegExpLegacyStaticsForMatch(rt, global, input_value, found);

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
    found: *const RegExpMatch,
    matched: core.JSValue,
) !void {
    std.debug.assert(out.flags.is_array);
    std.debug.assert(out.arrayLength() == 0);
    std.debug.assert(out.arrayElements().len == 0);
    std.debug.assert(out.arrayElementsCapacity() == 0);

    const element_count = found.capture_count + 1;
    const elements = try rt.memory.alloc(core.JSValue, element_count);
    var initialized: usize = 0;
    var transferred = false;
    errdefer {
        if (!transferred) {
            for (elements[0..initialized]) |value| value.free(rt);
            rt.memory.free(core.JSValue, elements);
        }
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
            elements[element_index] = capture_value;
        }
        initialized += 1;
    }

    out.adoptDenseArrayElementsAssumingEmpty(elements[0..element_count]);
    transferred = true;
    out.flags.may_have_indexed_properties = true;
}

pub fn createRegExpMatchArrayNoCapturesFromValue(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch, input_len: usize, has_indices: bool) !core.JSValue {
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
    found: *const RegExpMatch,
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

pub fn updateRegExpLegacyStaticsForMatch(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch) !void {
    if (try updateRegExpLegacyStaticsLazyForMatch(rt, global, input_value, found)) return;

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

pub fn updateRegExpLegacyStaticsLazyForMatch(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: *const RegExpMatch) !bool {
    var encoded_captures: [9]?core.JSValue = @splat(null);
    var encoded_last_paren: ?core.JSValue = null;

    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const capture = found.captures[capture_index];
        if (capture.undefined) continue;
        const encoded = encodeRegExpLegacyCaptureSlice(capture.start, capture.len) orelse return false;
        if (capture_index < encoded_captures.len) encoded_captures[capture_index] = encoded;
        encoded_last_paren = encoded;
    }

    const regexp_ctor = regExpConstructorFromGlobal(rt, global) catch return true;
    if (regexp_ctor.class_payload_kind != .function) return true;
    const legacy = try regexp_ctor.ensureRegExpLegacyStatics(rt);
    const already_lazy = legacy.lazy_no_capture_match;

    try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.input, input_value);
    if (!already_lazy) {
        clearRegExpLegacySlot(rt, &legacy.last_match);
        clearRegExpLegacySlot(rt, &legacy.left_context);
        clearRegExpLegacySlot(rt, &legacy.right_context);
    }

    if (encoded_last_paren) |value| {
        try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.last_paren, value);
    } else {
        clearRegExpLegacySlot(rt, &legacy.last_paren);
    }

    var slot_index: usize = 0;
    while (slot_index < legacy.captures.len) : (slot_index += 1) {
        if (encoded_captures[slot_index]) |value| {
            try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.captures[slot_index], value);
        } else {
            clearRegExpLegacySlot(rt, &legacy.captures[slot_index]);
        }
    }

    legacy.lazy_no_capture_match = true;
    legacy.lazy_match_index = found.index;
    legacy.lazy_match_len = found.len;
    legacy.lazy_input_len = try stringLengthIndex(rt, input_value);
    return true;
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
    return unicode_lib.appendUtf8CodePoint(rt.memory.allocator, out, cp);
}

pub fn isHighSurrogateCodePoint(cp: u21) bool {
    return unicode_lib.isHighSurrogateCodePoint(cp);
}

pub fn isLowSurrogateCodePoint(cp: u21) bool {
    return unicode_lib.isLowSurrogateCodePoint(cp);
}

pub fn combinedSurrogateCodePoint(high: u16, low: u16) u21 {
    return unicode_lib.codePointFromSurrogatePair(high, low);
}

pub fn createRegExpMatchArrayFromStringValue(rt: *core.JSRuntime, input_value: core.JSValue, found: *const RegExpMatch) !core.JSValue {
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
    const string_value = value.asStringBody() orelse return value.dup();
    const input_len = string_value.len();
    const slice_start = @min(start, input_len);
    const slice_end = @min(input_len, slice_start + len);
    const slice_len = slice_end - slice_start;
    if (slice_start == 0 and slice_len == input_len) return value.dup();
    if (slice_len == 0) return (try rt.emptyString()).value().dup();
    try string_value.ensureFlat(rt);
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
    return string_id_lookup.decodePrototypeMethodId(native_ref.id);
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
    if (std.mem.eql(u8, name, "normalize")) return string_id_lookup.legacy_normalize_method_id;
    if (std.mem.eql(u8, name, "isWellFormed")) return 38;
    if (std.mem.eql(u8, name, "toWellFormed")) return 39;
    if (std.mem.eql(u8, name, "search")) return string_id_lookup.legacy_search_method_id;
    if (std.mem.eql(u8, name, "match")) return string_id_lookup.legacy_match_method_id;
    if (std.mem.eql(u8, name, "replaceAll")) return string_id_lookup.legacy_replace_all_method_id;
    if (std.mem.eql(u8, name, "matchAll")) return string_id_lookup.legacy_match_all_method_id;
    return null;
}

pub fn primitiveStringMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return 9;
    if (std.mem.eql(u8, name, "concat")) return 10;
    if (standardStringMethodId(name)) |method_id| {
        if (method_id == string_id_lookup.legacy_match_all_method_id) return null;
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
    if (std.mem.eql(u8, name, "split")) return string_id_lookup.legacy_split_method_id;
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
            @intFromEnum(method_ids.array.PrototypeMethod.last_index_of) => .last_index_of,
            @intFromEnum(method_ids.array.PrototypeMethod.index_of) => .index_of,
            @intFromEnum(method_ids.array.PrototypeMethod.includes) => .includes,
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
    const is_typed_array = core.object.isTypedArrayObject(object);
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
    else if (object.flags.is_array)
        @as(usize, @intCast(object.arrayLength()))
    else blk: {
        const length_value = try getValueProperty(ctx, output, global, receiver_object_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk try toLengthIndex(ctx, output, global, length_value);
    };
    if (length == 0) return if (mode == .includes) core.JSValue.boolean(false) else core.JSValue.int32(-1);

    const search_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    // Typed arrays: raw-buffer per-class scan (qjs js_typed_array_indexOf,
    // quickjs.c:58072 / :58179-58245). Normalize the search value once with an
    // early can't-fit short-circuit, then scan the backing buffer per element
    // kind instead of boxing each element through typedArrayGetIndex. The
    // fromIndex coercion below mirrors what the generic loop already ran.
    if (is_typed_array) {
        const search_mode: array_ops.TypedSearchMode = switch (mode) {
            .index_of => .index_of,
            .last_index_of => .last_index_of,
            .includes => .includes,
        };
        const cursor = if (mode == .last_index_of)
            try arrayLastIndexStart(ctx, output, global, args, length)
        else
            try arrayFirstIndexStart(ctx, output, global, args, length);
        return try array_ops.qjsTypedArraySearchScan(ctx.runtime, object, search_mode, search_value, cursor, length);
    }
    if (mode == .last_index_of and length > 1_000_000) {
        return try qjsArrayLastIndexSparseLarge(ctx, output, global, object, receiver_object_value, args, length, search_value);
    }
    if (mode == .last_index_of) {
        var cursor = try arrayLastIndexStart(ctx, output, global, args, length);
        // Dense fast scan (qjs js_array_lastIndexOf js_get_fast_array loop,
        // quickjs.c:42476): if the receiver is still a dense fast array and the
        // fromIndex coercion above did not resize it, scan the borrowed element
        // slice directly — no per-element propertyAtomFromLengthIndex intern +
        // generic getValueProperty. `===` runs no user code, so the slice stays
        // valid for the whole loop.
        if (!is_typed_array and object.isFastArray() and @as(usize, @intCast(object.arrayLength())) == length and object.arrayElements().len == length) {
            const elements = object.arrayElements();
            if (cursor > elements.len) cursor = elements.len;
            while (cursor > 0) {
                cursor -= 1;
                if (try valuesStrictEqual(ctx.runtime, elements[cursor], search_value)) return lengthIndexValue(cursor);
            }
            return core.JSValue.int32(-1);
        }
        while (cursor > 0) {
            cursor -= 1;
            const item = if (is_typed_array) blk: {
                const current_length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
                if (cursor >= current_length) continue;
                break :blk try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(cursor));
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
        // Dense fast PREFIX scan, then fall through to the generic tail (qjs
        // js_array_indexOf/includes: js_get_fast_array dense loop over [0, count) then the
        // generic loop over [count, len) for the tail holes, quickjs.c:42426-42483). Unlike
        // a full-density gate, this also fast-scans the dense prefix of an L3 holey fast
        // array (array_count < length) before the proto-aware tail.
        if (!is_typed_array and object.isFastArray()) {
            const elements = object.arrayElements();
            const dense_end = @min(elements.len, length);
            while (cursor < dense_end) : (cursor += 1) {
                const item = elements[cursor];
                if (mode == .includes) {
                    if (item.sameValueZero(search_value)) return core.JSValue.boolean(true);
                } else {
                    if (try valuesStrictEqual(ctx.runtime, item, search_value)) return lengthIndexValue(cursor);
                }
            }
            // cursor == dense_end; the generic loop below covers [dense_end, length) holes.
        }
        while (cursor < length) : (cursor += 1) {
            const item = if (is_typed_array) blk: {
                if (mode != .includes) {
                    const current_length = @as(usize, @intCast(try core.object.typedArrayLength(ctx.runtime, object)));
                    if (cursor >= current_length) continue;
                }
                break :blk try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(cursor));
            } else blk: {
                const key = try propertyAtomFromLengthIndex(ctx.runtime, cursor);
                defer key.deinit(ctx.runtime);
                if (mode != .includes and !try hasValueProperty(ctx, output, global, receiver_object_value, object, key.atom, null, null)) continue;
                break :blk try getValueProperty(ctx, output, global, receiver_object_value, key.atom, null, null);
            };
            defer item.free(ctx.runtime);
            if (mode == .includes) {
                if (item.sameValueZero(search_value)) return core.JSValue.boolean(true);
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
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(method_ids.array.PrototypeMethod.concat))) {
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
    if (!core.object.isTypedArrayObject(object) or object.typedArrayFixedLength() == null) return dynamic;
    if (try core.object.typedArrayOutOfBounds(object)) return dynamic;
    const own = object.getOwnProperty(ctx.runtime, core.atom.ids.length) orelse return dynamic;
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
    const string_value = value.asStringBody() orelse return error.TypeError;
    try string_value.ensureFlat(rt);
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
    return unicode_lib.appendUtf8CodePoint(rt.memory.allocator, buffer, codepoint);
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
    // Resolve any String.prototype own method straight off the prototype without
    // materializing a boxed String wrapper. Restricting to predefined, non-index
    // atoms (excluding `length`, which is the primitive's own length, not
    // `String.prototype.length`) keeps `s[i]`/`s.length`/dynamic-name accesses on
    // their existing paths. This must cover NOT ONLY the `prototypeMethodId`
    // method-table methods (charCodeAt, split, match, …) but also the
    // String.prototype methods installed as plain functions (concat, replace,
    // replaceAll, the AnnexB html helpers). Before this, `"x".replace(...)`
    // missed the bitset gate and fell into `primitiveObjectForAccess`, which
    // builds a String wrapper with one own property per character of the
    // receiver -- O(n) per call, ~13x slower than QuickJS on string `.replace`.
    if (core.atom.isTaggedInt(atom_id) or atom_id == 0 or atom_id > core.atom.predefined_count) return null;
    if (atom_id == core.atom.ids.length) return null;

    // `constructorPrototypeFromGlobal(.., "String")` interns the atom "String" on
    // EVERY `s.method()` resolution (the internString hot spot) before walking
    // `global.String -> .prototype`. "String" is a predefined atom, so resolve it
    // at comptime and walk with the cached id — no per-call atom allocation.
    const string_ctor_atom = comptime core.atom.predefinedId("String", .string).?;
    const proto = object_ops.constructorPrototypeFromGlobalAtom(ctx.runtime, global, string_ctor_atom) orelse return null;
    return ownDataOrAutoInitPropertyValue(proto, atom_id);
}

/// Comptime bitset of the predefined atom ids whose name is a standard
/// String.prototype method. Built from the SAME `prototypeMethodId` map, so the
/// membership result is identical — but the per-access check below becomes an
/// O(1) integer-indexed lookup instead of `atoms.name()` + a ~40-way
/// `std.mem.eql` chain on every `s.method()` resolution. A user string equal to
/// a method name interns to its predefined atom id (interning is by content),
/// so dynamic atoms (id > predefined_count) are correctly never methods.
const string_method_atom_bits = blk: {
    @setEvalBranchQuota(400000);
    var bits = [_]bool{false} ** (core.atom.predefined_count + 1);
    for (core.atom.predefined_atoms) |pa| {
        if (pa.kind == .string and string_id_lookup.prototypeMethodId(pa.name) != null) {
            bits[pa.id] = true;
        }
    }
    break :blk bits;
};

pub fn isStandardStringPrototypeMethodAtom(rt: *core.JSRuntime, atom_id: core.Atom) bool {
    _ = rt;
    if (core.atom.isTaggedInt(atom_id) or atom_id == 0 or atom_id > core.atom.predefined_count) return false;
    return string_method_atom_bits[atom_id];
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
    const string_value = value.asStringBody() orelse return null;
    if (index >= string_value.len()) return core.JSValue.undefinedValue();
    try string_value.ensureFlat(rt);
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
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(method_ids.array.PrototypeMethod.to_string))) {
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
    if (!isArrayPrototypeRecord(function_object, @intFromEnum(method_ids.array.PrototypeMethod.to_locale_string))) {
        if (function_object.arrayBuiltinMarker() != .to_locale_string) return null;
    }
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (this_value.isObject()) this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    const object = property_ops.expectObject(object_value) catch return null;
    const is_typed_method = isTypedArrayPrototypeMethod(ctx.runtime, function_object);
    const is_typed_array = core.object.isTypedArrayObject(object);
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
            break :blk try core.typed_array.typedArrayGetIndex(ctx.runtime, object, @intCast(index));
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
    if (object.flags.is_proxy) {
        if (object.proxyHandler() == null) return error.TypeError;
        if (object.proxyTarget()) |target_value| {
            if (objectFromValue(target_value)) |target| {
                if (try objectIsArrayForToString(target)) return "Array";
                if (proxyTargetIsCallableObject(target)) return "Function";
            }
        }
        return "Object";
    }
    if (object.flags.is_array) return "Array";
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
    if (object.flags.is_array) return true;
    if (!object.flags.is_proxy) return false;
    if (object.proxyHandler() == null) return error.TypeError;
    const target_value = object.proxyTarget() orelse return false;
    const target = objectFromValue(target_value) orelse return false;
    return objectIsArrayForToString(target);
}

pub fn stringObjectHasIndexProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    if (object.class_id != core.class.ids.string) return false;
    const string_data = object.objectData() orelse return false;
    const index = core.array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return false;
    const string_value = string_data.asStringBody() orelse return false;
    return index < string_value.len();
}

// String unit/byte classification helpers (moved from the VM call runtime).

pub fn bytesAreAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!byteIsAscii(byte)) return false;
    }
    return true;
}

pub fn byteIsAscii(byte: u8) bool {
    return byte < 0x80;
}

pub fn appendUtf16UnitsAsUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void {
    return unicode_lib.appendUtf16UnitsAsUtf8(rt.memory.allocator, buffer, units);
}
pub fn appendAsciiUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), bytes: []const u8) !void {
    for (bytes) |byte| try out.append(rt.memory.allocator, byte);
}

pub fn isLineTerminatorUnit(unit: u16) bool {
    return unicode_lib.isEcmaLineTerminatorUnit(unit);
}

pub fn isEcmaWhitespaceOrLineTerminator(unit: u16) bool {
    return unicode_lib.isEcmaWhitespaceOrLineTerminatorUnit(unit);
}

pub fn isAsciiDigitUnit(unit: u16) bool {
    return unicode_lib.isAsciiDigitUnit(unit);
}

pub fn isAsciiDigitByte(byte: u8) bool {
    return unicode_lib.isAsciiDigitByte(byte);
}

pub fn isAsciiWordUnit(unit: u16) bool {
    return unicode_lib.isAsciiWordUnit(unit);
}

pub fn isHighSurrogateUnit(unit: u16) bool {
    return unicode_lib.isHighSurrogateUnit(unit);
}

pub fn isLowSurrogateUnit(unit: u16) bool {
    return unicode_lib.isLowSurrogateUnit(unit);
}

// ---------------------------------------------------------------------------
// Realm-aware String.prototype method bodies (pad / HTML wrappers / normalize /
// localeCompare / numeric-arg methods). These are reachable ONLY through the
// `qjsStringPrototypeMethod` dispatcher above (the `.string` builtin record
// handler `stringCall` routes every prototype method to it), never from a
// builtin dispatch table entry, so they are exec-only. They were briefly hosted
// in `builtins/string.zig` (Phase 6b-2) and were moved back here in Phase 6b-3
// STEP 3B to keep the dependency edge exec -> builtins out of these bodies. They
// reuse the file-local rope/UTF helpers (`toStringForAnnexB`,
// `appendStringValueUnits`, `appendUtf32FromStringValue`, `appendUtf16CodePoint`,
// `appendAsciiUnits`) plus the shared `value_ops`/`coercion_ops`/`builtin_glue`
// ops. The two leaf bodies they still defer to (the `charAtValue` and
// `methodCall` method-impl bodies that stay in builtins) are reached through the
// record table via `callStringBody`/`callStringCharAtBody` (Phase 6b-3 STEP 5),
// so exec no longer names them directly.

// qjs JS_STRING_LEN_MAX (quickjs.c:212): js_string_pad throws RangeError when the
// requested length exceeds it (quickjs.c:46331).
const js_string_len_max: usize = (1 << 30) - 1;

/// A narrow-first pad accumulator mirroring qjs's StringBuffer (js_string_pad,
/// quickjs.c:46304-46356): source/fill code units are copied into a latin1 (u8)
/// buffer and only widened to UTF-16 when a unit exceeds 0xFF, so an all-latin1
/// pad never materializes a UTF-16 result. It operates on code UNITS (surrogate
/// halves are copied verbatim, matching string_buffer_concat) and tiles the fill
/// by repetition+remainder rather than per character.
const PadBuffer = struct {
    allocator: std.mem.Allocator,
    latin1: std.ArrayList(u8) = .empty,
    wide: std.ArrayList(u16) = .empty,
    is_wide: bool = false,

    fn deinit(self: *PadBuffer) void {
        self.latin1.deinit(self.allocator);
        self.wide.deinit(self.allocator);
    }

    fn widen(self: *PadBuffer) !void {
        self.is_wide = true;
        try self.wide.ensureTotalCapacity(self.allocator, self.latin1.items.len);
        for (self.latin1.items) |byte| self.wide.appendAssumeCapacity(byte);
        self.latin1.clearRetainingCapacity();
    }

    fn ensureCapacity(self: *PadBuffer, additional: usize) !void {
        if (self.is_wide)
            try self.wide.ensureUnusedCapacity(self.allocator, additional)
        else
            try self.latin1.ensureUnusedCapacity(self.allocator, additional);
    }

    /// Appends `count` code units of `data` starting at `start`, widening on the
    /// first >0xFF unit encountered (mirrors string_buffer_concat's widen path).
    fn appendUnits(self: *PadBuffer, data: core.string.String.ResolvedData, start: usize, count: usize) !void {
        switch (data) {
            // latin1 units are all <= 0xFF: copy flat, no widen check needed.
            .latin1 => |bytes| {
                const chunk = bytes[start .. start + count];
                if (self.is_wide) {
                    try self.wide.ensureUnusedCapacity(self.allocator, count);
                    for (chunk) |byte| self.wide.appendAssumeCapacity(byte);
                } else {
                    try self.latin1.appendSlice(self.allocator, chunk);
                }
            },
            .utf16 => |units| {
                const chunk = units[start .. start + count];
                try self.ensureCapacity(count);
                var i: usize = 0;
                while (i < chunk.len) : (i += 1) {
                    const unit = chunk[i];
                    if (!self.is_wide) {
                        if (unit <= 0xff) {
                            self.latin1.appendAssumeCapacity(@intCast(unit));
                            continue;
                        }
                        // Widen, then reserve room for the rest of this chunk
                        // (already-copied units moved into `wide`).
                        try self.widen();
                        try self.wide.ensureUnusedCapacity(self.allocator, chunk.len - i);
                    }
                    self.wide.appendAssumeCapacity(unit);
                }
            },
        }
    }

    fn finish(self: *PadBuffer, rt: *core.JSRuntime) !core.JSValue {
        const string = if (self.is_wide)
            try core.string.String.createUtf16(rt, self.wide.items)
        else
            try core.string.String.createLatin1(rt, self.latin1.items);
        return string.value();
    }
};

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

    // Resolve the source to its flat code-unit slice ONCE (no per-char UTF-16
    // copy of the whole source — qjs reads p->len from the JSString directly,
    // quickjs.c:46313-46314).
    const source = string_value.asStringBody() orelse return error.TypeError;
    try source.ensureFlat(ctx.runtime);
    const source_data = source.resolveData();
    const source_len = source_data.len();

    const max_length_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const target_length = try coercion_ops.toLengthIndex(ctx, output, global, max_length_value);
    if (target_length <= source_len) return string_value.dup();

    const fill_value = if (args.len >= 2 and !args[1].isUndefined()) blk: {
        break :blk try toStringForAnnexB(ctx, output, global, args[1], caller_function, caller_frame);
    } else try value_ops.createStringValue(ctx.runtime, " ");
    defer fill_value.free(ctx.runtime);

    const fill = fill_value.asStringBody() orelse return error.TypeError;
    try fill.ensureFlat(ctx.runtime);
    const fill_data = fill.resolveData();
    const fill_len = fill_data.len();
    if (fill_len == 0) return string_value.dup();

    // qjs caps the result at JS_STRING_LEN_MAX (quickjs.c:46331-46334); without
    // this an out-of-range maxLength would attempt a multi-GiB allocation instead
    // of the spec/qjs RangeError.
    if (target_length > js_string_len_max) return throwRangeErrorMessage(ctx, global, "invalid string length");
    const pad_count = target_length - source_len;

    var buffer = PadBuffer{ .allocator = ctx.runtime.memory.allocator };
    defer buffer.deinit();
    try buffer.ensureCapacity(target_length);

    // padEnd: source first, then fill. padStart: fill first, then source.
    // (quickjs.c:46338-46356, magic 0 = padStart / 1 = padEnd; here 34 = start.)
    if (method_id == 35) try buffer.appendUnits(source_data, 0, source_len);

    var remaining = pad_count;
    while (remaining > 0) {
        const chunk = @min(remaining, fill_len);
        try buffer.appendUnits(fill_data, 0, chunk);
        remaining -= chunk;
    }

    if (method_id == 34) try buffer.appendUnits(source_data, 0, source_len);

    return buffer.finish(ctx.runtime);
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

const NormalizedUtf32 = struct {
    allocator: std.mem.Allocator,
    slice: []u32,

    fn deinit(self: NormalizedUtf32) void {
        self.allocator.free(self.slice);
    }
};

fn normalizedUtf32(rt: *core.JSRuntime, value: core.JSValue, form: unicode_lib.NormalizationForm) !NormalizedUtf32 {
    var input = std.ArrayList(u32).empty;
    defer input.deinit(rt.memory.allocator);
    try appendUtf32FromStringValue(rt, &input, value);
    return .{
        .allocator = rt.memory.allocator,
        .slice = try unicode_lib.normalizeAlloc(rt.memory.allocator, input.items, form),
    };
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
            try builtin_glue.toNumberLikeArgument(ctx, output, global, arg);
    }

    if (method_id == 1) {
        if (try fastLatin1Substring(ctx.runtime, string_value, coerced[0..count])) |value| return value;
    }
    if (method_id == 0) {
        const index = if (count >= 1) coerced[0] else core.JSValue.int32(0);
        return callStringCharAtBody(ctx, string_value, index);
    }
    if (method_id == 25) {
        return qjsStringSubstr(ctx, output, global, string_value, coerced[0..count]);
    }
    return callStringBody(ctx, string_value, method_id, coerced[0..count]) catch |err| switch (err) {
        error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid repeat count"),
        else => err,
    };
}

fn fastLatin1Substring(rt: *core.JSRuntime, string_value: core.JSValue, args: []const core.JSValue) !?core.JSValue {
    if (!string_value.isString() or args.len > 2) return null;
    const string = string_value.asStringBody() orelse return null;
    try string.ensureFlat(rt);
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

fn int32OrUndefinedStringIndex(value: core.JSValue) ?i64 {
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

fn qjsStringCreateHtml(
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
