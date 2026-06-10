pub const createNamedError = exception_ops.createNamedError;

pub const regexp_unicode = @import("../libs/regexp_unicode.zig");
pub const createNamedErrorWithConstructor = exception_ops.createNamedErrorWithConstructor;
pub const normalizeEvalRuntimeError = exception_ops.normalizeEvalRuntimeError;
pub const rejectedPromiseForRuntimeError = exception_ops.rejectedPromiseForRuntimeError;
pub const throwTdzReference = exception_ops.throwTdzReference;
pub const isCallSiteObject = exception_ops.isCallSiteObject;
pub const qjsCallSiteMethod = exception_ops.qjsCallSiteMethod;
pub const isErrorConstructorName = exception_ops.isErrorConstructorName;
const std = @import("std");
const utils = @import("vm_utils.zig");
const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const bignum = @import("../libs/bignum.zig");
const core = @import("../core/root.zig");
const frontend = @import("../frontend/root.zig");
const quickjs_regexp = @import("../libs/quickjs_regexp.zig");
const unicode_lib = @import("../libs/unicode.zig");
const call_mod = @import("call.zig");
const collection_vm = @import("array_ops.zig");
const construct_mod = @import("construct.zig");
const date_vm = @import("date_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const frame_mod = @import("frame.zig");
const iter_vm = @import("iterator_ops.zig");
const json_vm = @import("json_ops.zig");
const module_mod = @import("module.zig");
const property_ops = @import("property_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");
const HostError = exceptions.HostError;
const libc = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("poll.h");
});
const op = bytecode.opcode.op;
const eval_ret_atom: core.Atom = 82;
const runWithArgs = zjs_vm.runWithArgs;
const runWithArgsState = zjs_vm.runWithArgsState;
const exceptions = @import("exceptions.zig");

pub const string_ops = @import("string_ops.zig");
pub const FastReplacementPart = string_ops.FastReplacementPart;
pub const FastReplacementPattern = string_ops.FastReplacementPattern;
pub const KeywordMatch = string_ops.KeywordMatch;
pub const RegExpMatch = string_ops.RegExpMatch;
pub const ReplaceMatch = string_ops.ReplaceMatch;
pub const advanceStringIndexNumber = string_ops.advanceStringIndexNumber;
pub const advanceStringIndexStringValue = string_ops.advanceStringIndexStringValue;
pub const advanceStringIndexUnits = string_ops.advanceStringIndexUnits;
pub const anchoredBinaryPropertyMatches = string_ops.anchoredBinaryPropertyMatches;
pub const anchoredCodePointPredicateMatches = string_ops.anchoredCodePointPredicateMatches;
pub const anchoredComplementClassMatches = string_ops.anchoredComplementClassMatches;
pub const anchoredRgiEmojiMatches = string_ops.anchoredRgiEmojiMatches;
pub const anchoredSingleNonWhitespaceMatches = string_ops.anchoredSingleNonWhitespaceMatches;
pub const anchoredStringPropertyName = string_ops.anchoredStringPropertyName;
pub const anchoredWhitespaceMatches = string_ops.anchoredWhitespaceMatches;
pub const annexBStringMethodId = string_ops.annexBStringMethodId;
pub const appendCodePointUnits = string_ops.appendCodePointUnits;
pub const appendCodepointUtf8 = string_ops.appendCodepointUtf8;
pub const appendFastReplacement = string_ops.appendFastReplacement;
pub const appendSourceStringUtf8 = string_ops.appendSourceStringUtf8;
pub const appendStringReplaceAllSubstitution = string_ops.appendStringReplaceAllSubstitution;
pub const appendStringValueUnits = string_ops.appendStringValueUnits;
pub const appendUtf16CodePoint = string_ops.appendUtf16CodePoint;
pub const appendUtf32FromStringValue = string_ops.appendUtf32FromStringValue;
pub const appendUtf8CodePointForRegExpName = string_ops.appendUtf8CodePointForRegExpName;
pub const binaryPropertyCodePointMatches = string_ops.binaryPropertyCodePointMatches;
pub const buildErrorStackStringValue = string_ops.buildErrorStackStringValue;
pub const callReplaceFunction = string_ops.callReplaceFunction;
pub const callSimpleStringBytecode = string_ops.callSimpleStringBytecode;
pub const callStringReplaceMethod = string_ops.callStringReplaceMethod;
pub const callStringWellKnownMethod = string_ops.callStringWellKnownMethod;
pub const isOutputExternalHostFunction = call_mod.isOutputExternalHostFunction;
pub const isOutputExternalHostFunctionId = call_mod.isOutputExternalHostFunctionId;
pub const captureReplaceMatch = string_ops.captureReplaceMatch;
pub const classEscapeUnitMatches = string_ops.classEscapeUnitMatches;
pub const codePointFromSurrogatePair = string_ops.codePointFromSurrogatePair;
pub const combinedSurrogateCodePoint = string_ops.combinedSurrogateCodePoint;
pub const complementClassUnitMatches = string_ops.complementClassUnitMatches;
pub const concatAppendValue = string_ops.concatAppendValue;
pub const concatSpreadLengthValue = string_ops.concatSpreadLengthValue;
pub const consumePendingExceptionIfMatchesConstructor = string_ops.consumePendingExceptionIfMatchesConstructor;
pub const createRegExpMatchArray = string_ops.createRegExpMatchArray;
pub const createRegExpMatchArrayFromStringSliceValue = string_ops.createRegExpMatchArrayFromStringSliceValue;
pub const createRegExpMatchArrayFromStringValue = string_ops.createRegExpMatchArrayFromStringValue;
pub const createRegExpMatchArrayFromValue = string_ops.createRegExpMatchArrayFromValue;
pub const createRegExpMatchArrayNoCapturesFromValue = string_ops.createRegExpMatchArrayNoCapturesFromValue;
pub const createStartOfLineUnicodeMatchArray = string_ops.createStartOfLineUnicodeMatchArray;
pub const createStringFromByteUnits = string_ops.createStringFromByteUnits;
pub const defaultObjectToStringTag = string_ops.defaultObjectToStringTag;
pub const defineSplitStringElement = string_ops.defineSplitStringElement;
pub const defineSplitUnitsElement = string_ops.defineSplitUnitsElement;
pub const defineSplitValueElement = string_ops.defineSplitValueElement;
pub const defineStringWrapperIndexProperty = string_ops.defineStringWrapperIndexProperty;
pub const fastLatin1Substring = string_ops.fastLatin1Substring;
pub const findCharacterClassSourceMatch = string_ops.findCharacterClassSourceMatch;
pub const findLeadingAlternationCharacterClassSingleUnitMatch = string_ops.findLeadingAlternationCharacterClassSingleUnitMatch;
pub const findPropertyEscapeMatch = string_ops.findPropertyEscapeMatch;
pub const findStandaloneCharacterClassMatch = string_ops.findStandaloneCharacterClassMatch;
pub const findStringClassEscapeMatch = string_ops.findStringClassEscapeMatch;
pub const findStringPropertyEscapeMatch = string_ops.findStringPropertyEscapeMatch;
pub const findStringUnitMatch = string_ops.findStringUnitMatch;
pub const findUnicodeFoldClassMatch = string_ops.findUnicodeFoldClassMatch;
pub const findUnicodePropertyOnlyClassMatch = string_ops.findUnicodePropertyOnlyClassMatch;
pub const formatCapturedErrorStackStringValue = string_ops.formatCapturedErrorStackStringValue;
pub const freeReplaceMatches = string_ops.freeReplaceMatches;
pub const genericTrimStringMethodId = string_ops.genericTrimStringMethodId;
pub const getFastStringPrimitiveDataProperty = string_ops.getFastStringPrimitiveDataProperty;
pub const getRegExpFlagsString = string_ops.getRegExpFlagsString;
pub const getRegExpFlagsStringForReplace = string_ops.getRegExpFlagsStringForReplace;
pub const getStringIndexValue = string_ops.getStringIndexValue;
pub const getStringPrototypeMethodId = string_ops.getStringPrototypeMethodId;
pub const getSubstitutionString = string_ops.getSubstitutionString;
pub const initRegExpMatchArrayDenseElementsFromValue = string_ops.initRegExpMatchArrayDenseElementsFromValue;
pub const int32OrUndefinedStringIndex = string_ops.int32OrUndefinedStringIndex;
pub const isConcatSpreadable = string_ops.isConcatSpreadable;
pub const isEmptyStringValue = string_ops.isEmptyStringValue;
pub const isHighSurrogateCodePoint = string_ops.isHighSurrogateCodePoint;
pub const isLowSurrogateCodePoint = string_ops.isLowSurrogateCodePoint;
pub const isRegExpForStringSearch = string_ops.isRegExpForStringSearch;
pub const isSimpleStringClassEscapeSource = string_ops.isSimpleStringClassEscapeSource;
pub const isStandardStringPrototypeMethodAtom = string_ops.isStandardStringPrototypeMethodAtom;
pub const isStringHighSurrogateAt = string_ops.isStringHighSurrogateAt;
pub const isStringLineEndPosition = string_ops.isStringLineEndPosition;
pub const isStringLineStartPosition = string_ops.isStringLineStartPosition;
pub const isStringMethodReceiver = string_ops.isStringMethodReceiver;
pub const isUnicodePropertyMatches = regexp_unicode.isUnicodePropertyMatches;
pub const latin1StringSlice = string_ops.latin1StringSlice;
pub const nativeFunctionMatcherUnicodeClassAsciiResult = string_ops.nativeFunctionMatcherUnicodeClassAsciiResult;
pub const objectIsArrayForToString = string_ops.objectIsArrayForToString;
pub const parseFastReplacementPattern = string_ops.parseFastReplacementPattern;
pub const privateAtomNamesMatch = string_ops.privateAtomNamesMatch;
pub const qjsArrayConcatCall = string_ops.qjsArrayConcatCall;
pub const qjsArraySearchCall = string_ops.qjsArraySearchCall;
pub const qjsArrayToLocaleStringCall = string_ops.qjsArrayToLocaleStringCall;
pub const qjsArrayToStringCall = string_ops.qjsArrayToStringCall;
pub const qjsBigIntPrototypeToString = string_ops.qjsBigIntPrototypeToString;
pub const qjsDefineToStringTag = string_ops.qjsDefineToStringTag;
pub const qjsErrorToStringCall = string_ops.qjsErrorToStringCall;
pub const qjsFunctionToStringCall = string_ops.qjsFunctionToStringCall;
pub const qjsIteratorConcatCall = string_ops.qjsIteratorConcatCall;
pub const qjsObjectTagString = string_ops.qjsObjectTagString;
pub const qjsObjectToLocaleStringCall = string_ops.qjsObjectToLocaleStringCall;
pub const qjsObjectToStringCall = string_ops.qjsObjectToStringCall;
pub const qjsObjectToStringIntrinsic = string_ops.qjsObjectToStringIntrinsic;
pub const qjsRegExpAutoInitBuiltinMatches = string_ops.qjsRegExpAutoInitBuiltinMatches;
pub const qjsRegExpMatch = string_ops.qjsRegExpMatch;
pub const qjsRegExpNativeBuiltinMatches = string_ops.qjsRegExpNativeBuiltinMatches;
pub const qjsRegExpSearch = string_ops.qjsRegExpSearch;
pub const qjsRegExpSplit = string_ops.qjsRegExpSplit;
pub const qjsRegExpSplitFlags = string_ops.qjsRegExpSplitFlags;
pub const qjsRegExpSplitWholeString = string_ops.qjsRegExpSplitWholeString;
pub const qjsRegExpStringIteratorNext = string_ops.qjsRegExpStringIteratorNext;
pub const qjsRegExpStringIteratorPrototype = string_ops.qjsRegExpStringIteratorPrototype;
pub const qjsRegExpSymbolMatch = string_ops.qjsRegExpSymbolMatch;
pub const qjsRegExpSymbolMatchAll = string_ops.qjsRegExpSymbolMatchAll;
pub const qjsRegExpSymbolMatchGeneric = string_ops.qjsRegExpSymbolMatchGeneric;
pub const qjsRegExpSymbolReplace = string_ops.qjsRegExpSymbolReplace;
pub const qjsRegExpSymbolReplaceGeneric = string_ops.qjsRegExpSymbolReplaceGeneric;
pub const qjsRegExpSymbolSearch = string_ops.qjsRegExpSymbolSearch;
pub const qjsRegExpSymbolSearchGeneric = string_ops.qjsRegExpSymbolSearchGeneric;
pub const qjsRegExpSymbolSplit = string_ops.qjsRegExpSymbolSplit;
pub const qjsRegExpSymbolSplitGeneric = string_ops.qjsRegExpSymbolSplitGeneric;
pub const qjsRegExpToString = string_ops.qjsRegExpToString;
pub const qjsStringConcat = string_ops.qjsStringConcat;
pub const qjsStringConstructWithPrototype = string_ops.qjsStringConstructWithPrototype;
pub const qjsStringCreateHtml = string_ops.qjsStringCreateHtml;
pub const qjsStringFromCharCode = string_ops.qjsStringFromCharCode;
pub const qjsStringFromCodePoint = string_ops.qjsStringFromCodePoint;
pub const qjsStringFromCodePointArray = string_ops.qjsStringFromCodePointArray;
pub const qjsStringFromCodePointDenseArray = string_ops.qjsStringFromCodePointDenseArray;
pub const qjsStringFunctionCall = string_ops.qjsStringFunctionCall;
pub const qjsStringHtmlMethod = string_ops.qjsStringHtmlMethod;
pub const qjsStringIterator = string_ops.qjsStringIterator;
pub const qjsStringLocaleCompare = string_ops.qjsStringLocaleCompare;
pub const qjsStringMatch = string_ops.qjsStringMatch;
pub const qjsStringMatchAll = string_ops.qjsStringMatchAll;
pub const qjsStringNormalize = string_ops.qjsStringNormalize;
pub const qjsStringNumericArgsMethod = string_ops.qjsStringNumericArgsMethod;
pub const qjsStringPad = string_ops.qjsStringPad;
pub const qjsStringPrototypeMethod = string_ops.qjsStringPrototypeMethod;
pub const qjsStringRaw = string_ops.qjsStringRaw;
pub const qjsStringRegExpCreateAndInvoke = string_ops.qjsStringRegExpCreateAndInvoke;
pub const qjsStringReplace = string_ops.qjsStringReplace;
pub const qjsStringReplaceAll = string_ops.qjsStringReplaceAll;
pub const qjsStringReplaceAllStringSearch = string_ops.qjsStringReplaceAllStringSearch;
pub const qjsStringReplaceFastRegExp = string_ops.qjsStringReplaceFastRegExp;
pub const qjsStringSearch = string_ops.qjsStringSearch;
pub const qjsStringSearchPositionMethod = string_ops.qjsStringSearchPositionMethod;
pub const qjsStringSplit = string_ops.qjsStringSplit;
pub const qjsStringSplitBuiltinArray = string_ops.qjsStringSplitBuiltinArray;
pub const qjsStringSubstr = string_ops.qjsStringSubstr;
pub const qjsStringTrim = string_ops.qjsStringTrim;
pub const qjsStringValueContainsByte = string_ops.qjsStringValueContainsByte;
pub const readUtf16CodePoint = string_ops.readUtf16CodePoint;
pub const regExpMatchHasNamedCaptures = string_ops.regExpMatchHasNamedCaptures;
pub const regexpInternalStringValue = string_ops.regexpInternalStringValue;
pub const replaceFrameVarRefBinding = string_ops.replaceFrameVarRefBinding;
pub const replaceGlobalSimpleCaptureSequence = string_ops.replaceGlobalSimpleCaptureSequence;
pub const replaceGlobalSimpleClassEscape = string_ops.replaceGlobalSimpleClassEscape;
pub const replaceRegExpLegacySlot = string_ops.replaceRegExpLegacySlot;
pub const replaceSingleUnitGlobalSimpleClassEscape = string_ops.replaceSingleUnitGlobalSimpleClassEscape;
pub const replacementCaptureUnits = string_ops.replacementCaptureUnits;
pub const simpleAsciiLiteralClassPlusLiteralMatchBytes = string_ops.simpleAsciiLiteralClassPlusLiteralMatchBytes;
pub const simpleAsciiLiteralPlusLiteralMatch = string_ops.simpleAsciiLiteralPlusLiteralMatch;
pub const simpleAsciiLiteralPlusLiteralMatchBytes = string_ops.simpleAsciiLiteralPlusLiteralMatchBytes;
pub const simpleLatin1LiteralPlusLiteralMatch = string_ops.simpleLatin1LiteralPlusLiteralMatch;
pub const simpleLatin1LiteralPlusLiteralMatchBytes = string_ops.simpleLatin1LiteralPlusLiteralMatchBytes;
pub const simpleCaptureSequenceAtomMatches = string_ops.simpleCaptureSequenceAtomMatches;
pub const simpleCaptureSequenceMatchLatin1 = string_ops.simpleCaptureSequenceMatchLatin1;
pub const simpleCaptureSequenceMatchPattern = string_ops.simpleCaptureSequenceMatchPattern;
pub const simpleCaptureSequenceMatchUtf16 = string_ops.simpleCaptureSequenceMatchUtf16;
pub const simpleClassAlternationMatchLatin1 = string_ops.simpleClassAlternationMatchLatin1;
pub const simpleClassAlternationMatchPattern = string_ops.simpleClassAlternationMatchPattern;
pub const simpleClassAlternationMatchUtf16 = string_ops.simpleClassAlternationMatchUtf16;
pub const simpleClassPredicateMatches = string_ops.simpleClassPredicateMatches;
pub const simpleClassSequenceAtomMatches = string_ops.simpleClassSequenceAtomMatches;
pub const simpleClassSequenceMatch = string_ops.simpleClassSequenceMatch;
pub const simpleClassSequenceMatchLatin1 = string_ops.simpleClassSequenceMatchLatin1;
pub const simpleClassSequenceMatchPattern = string_ops.simpleClassSequenceMatchPattern;
pub const simpleClassSequenceMatchUtf16 = string_ops.simpleClassSequenceMatchUtf16;
pub const simpleEvalStringLiteral = string_ops.simpleEvalStringLiteral;
pub const simpleUnicodeLiteralMatch = string_ops.simpleUnicodeLiteralMatch;
pub const singleDotAnchoredMatches = string_ops.singleDotAnchoredMatches;
pub const standardStringMethodId = string_ops.standardStringMethodId;
pub const primitiveStringMethodId = string_ops.primitiveStringMethodId;
pub const stringAtomId = string_ops.stringAtomId;
pub const stringCodePointAt = string_ops.stringCodePointAt;
pub const stringIndexOfUnits = string_ops.stringIndexOfUnits;
pub const stringIteratorPrototypeFromContext = string_ops.stringIteratorPrototypeFromContext;
pub const stringLengthIndex = string_ops.stringLengthIndex;
pub const stringObjectHasIndexProperty = string_ops.stringObjectHasIndexProperty;
pub const stringPropertyEscapePattern = string_ops.stringPropertyEscapePattern;
pub const stringSliceValue = string_ops.stringSliceValue;
pub const stringValueContainsUnitByte = string_ops.stringValueContainsUnitByte;
pub const stringValueUnits = string_ops.stringValueUnits;
pub const stringValueUnitsEqualBytes = string_ops.stringValueUnitsEqualBytes;
pub const surrogatePairFromCodePoint = string_ops.surrogatePairFromCodePoint;

pub const thrownValueMatchesConstructor = string_ops.thrownValueMatchesConstructor;
pub const toObjectForStringRaw = string_ops.toObjectForStringRaw;
pub const toOrdinaryPrimitiveString = string_ops.toOrdinaryPrimitiveString;
pub const toPrimitiveForString = string_ops.toPrimitiveForString;
pub const toStringBytesForSymbol = string_ops.toStringBytesForSymbol;
pub const toStringForAnnexB = string_ops.toStringForAnnexB;
pub const uint8ArrayStringBytes = string_ops.uint8ArrayStringBytes;
pub const unicodeAstralSpecialMatch = string_ops.unicodeAstralSpecialMatch;
pub const unicodeLowSurrogateLiteralMatch = string_ops.unicodeLowSurrogateLiteralMatch;
pub const unicodePropertyOnlyClassCodePointMatches = string_ops.unicodePropertyOnlyClassCodePointMatches;
pub const unicodePropertyRunCodePointMatches = string_ops.unicodePropertyRunCodePointMatches;
pub const unicodeSimpleFoldClassMatches = string_ops.unicodeSimpleFoldClassMatches;
pub const unicodeSurrogatePairClassMatch = string_ops.unicodeSurrogatePairClassMatch;
pub const updateRegExpLegacyStaticsForMatch = string_ops.updateRegExpLegacyStaticsForMatch;
pub const updateRegExpLegacyStaticsForMatchValues = string_ops.updateRegExpLegacyStaticsForMatchValues;
pub const validStringCodePoint = string_ops.validStringCodePoint;

pub const array_ops = @import("array_ops.zig");
pub const ArrayIterationMode = array_ops.ArrayIterationMode;
pub const ArraySortEntry = array_ops.ArraySortEntry;
pub const RegExpLegacyNoCaptureSlice = array_ops.RegExpLegacyNoCaptureSlice;
pub const TypedArrayCanonicalIndex = builtins.buffer.TypedArrayCanonicalIndex;
pub const TypedArrayLengthPrintLocalGet = array_ops.TypedArrayLengthPrintLocalGet;
pub const TypedArrayLengthPrintStore = array_ops.TypedArrayLengthPrintStore;
pub const Uint8ArrayBase64Alphabet = array_ops.Uint8ArrayBase64Alphabet;
pub const Uint8ArrayBase64LastChunkHandling = array_ops.Uint8ArrayBase64LastChunkHandling;
pub const Uint8ArrayCodecProgress = array_ops.Uint8ArrayCodecProgress;
pub const ValueSliceRoot = array_ops.ValueSliceRoot;
pub const addCollectionEntriesFromArray = array_ops.addCollectionEntriesFromArray;
pub const aggregateErrorsIterableToArray = array_ops.aggregateErrorsIterableToArray;
pub const argsFromArray = array_ops.argsFromArray;
pub const argsFromArrayLike = array_ops.argsFromArrayLike;
pub const arrayByCopySortCompare = array_ops.arrayByCopySortCompare;
pub const arrayConstructorFromGlobal = array_ops.arrayConstructorFromGlobal;
pub const arrayFirstIndexStart = array_ops.arrayFirstIndexStart;
pub const arrayIteratorPrototypeFromContext = array_ops.arrayIteratorPrototypeFromContext;
pub const arrayLastIndexStart = array_ops.arrayLastIndexStart;
pub const arrayLengthAssignmentValue = array_ops.arrayLengthAssignmentValue;
pub const arrayLengthDefineValue = array_ops.arrayLengthDefineValue;
pub const arrayMethodTypedArrayLength = array_ops.arrayMethodTypedArrayLength;
pub const arrayPrototypeChainHasNoIndexedProperties = array_ops.arrayPrototypeChainHasNoIndexedProperties;
pub const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
pub const arrayPrototypeRecordId = array_ops.arrayPrototypeRecordId;
pub const arrayPrototypeValuesFromGlobal = array_ops.arrayPrototypeValuesFromGlobal;
pub const arrayRelativeIndex = array_ops.arrayRelativeIndex;
pub const arrayRelativeIndexFromNumber = array_ops.arrayRelativeIndexFromNumber;
pub const arraySortCompare = array_ops.arraySortCompare;
pub const arraySpeciesConstructorIsForeignArray = array_ops.arraySpeciesConstructorIsForeignArray;
pub const arraySpeciesCreate = array_ops.arraySpeciesCreate;
pub const arraySpeciesOriginalIsArray = array_ops.arraySpeciesOriginalIsArray;
pub const arrayUsesDefaultIterator = array_ops.arrayUsesDefaultIterator;
pub const atomListToMemorySlice = array_ops.atomListToMemorySlice;
pub const atomSliceContains = array_ops.atomSliceContains;
pub const atomicsTypedArray = array_ops.atomicsTypedArray;
pub const atomicsTypedArrayIsBigInt = array_ops.atomicsTypedArrayIsBigInt;
pub const buildCallSiteArray = array_ops.buildCallSiteArray;
pub const coerceTypedArrayElementForSet = array_ops.coerceTypedArrayElementForSet;
pub const coerceTypedArrayElementInput = array_ops.coerceTypedArrayElementInput;
pub const constructArrayBufferNativeRecord = array_ops.constructArrayBufferNativeRecord;
pub const createArrayByCopyOutput = array_ops.createArrayByCopyOutput;
pub const createArrayFromArgs = array_ops.createArrayFromArgs;
pub const createRegExpIndicesArray = array_ops.createRegExpIndicesArray;
pub const createUint8ArrayFromBytes = array_ops.createUint8ArrayFromBytes;
pub const decodeTypedArrayLengthPrintLocalGet = array_ops.decodeTypedArrayLengthPrintLocalGet;
pub const decodeTypedArrayLengthPrintStore = array_ops.decodeTypedArrayLengthPrintStore;
pub const defaultArraySpeciesCreate = array_ops.defaultArraySpeciesCreate;
pub const defineArrayByCopyElement = array_ops.defineArrayByCopyElement;
pub const ensureLengthWritableForArrayBuiltin = array_ops.ensureLengthWritableForArrayBuiltin;
pub const ensureSettableForArrayBuiltin = array_ops.ensureSettableForArrayBuiltin;
pub const expectUint8ArrayObject = array_ops.expectUint8ArrayObject;
pub const flattenIntoArray = array_ops.flattenIntoArray;
pub const freeAtomSlice = array_ops.freeAtomSlice;
pub const freeValueSlice = array_ops.freeValueSlice;
pub const isArrayMethodReceiver = array_ops.isArrayMethodReceiver;
pub const isArrayPrototypeRecord = array_ops.isArrayPrototypeRecord;
pub const isArrayStaticRecord = array_ops.isArrayStaticRecord;
pub const isConstructorForArrayOf = array_ops.isConstructorForArrayOf;
pub const isTypedArrayInternalOwnKey = array_ops.isTypedArrayInternalOwnKey;
pub const isTypedArrayPrototypeMethod = array_ops.isTypedArrayPrototypeMethod;
pub const iteratorFlattenableForIteratorFrom = array_ops.iteratorFlattenableForIteratorFrom;
pub const nativeTypedArraySubclassBase = array_ops.nativeTypedArraySubclassBase;
pub const popCatchMarker = array_ops.popCatchMarker;
pub const popDuplicateConstructorTarget = array_ops.popDuplicateConstructorTarget;
pub const pushFunctionClosure = array_ops.pushFunctionClosure;
pub const pushSlotValue = array_ops.pushSlotValue;
pub const putDenseArrayElementFast = array_ops.putDenseArrayElementFast;
pub const qjsArrayAtCall = array_ops.qjsArrayAtCall;
pub const qjsArrayBufferAccessor = array_ops.qjsArrayBufferAccessor;
pub const qjsArrayBufferConstructWithPrototype = array_ops.qjsArrayBufferConstructWithPrototype;
pub const qjsArrayBufferIsView = array_ops.qjsArrayBufferIsView;
pub const qjsArrayBufferLengthArgument = array_ops.qjsArrayBufferLengthArgument;
pub const qjsArrayBufferMaxByteLengthOption = array_ops.qjsArrayBufferMaxByteLengthOption;
pub const qjsArrayBufferPrototypeFromTypedArrayPrototype = array_ops.qjsArrayBufferPrototypeFromTypedArrayPrototype;
pub const qjsArrayBufferPrototypeNativeRecord = array_ops.qjsArrayBufferPrototypeNativeRecord;
pub const qjsArrayBufferResize = array_ops.qjsArrayBufferResize;
pub const qjsArrayBufferSlice = array_ops.qjsArrayBufferSlice;
pub const qjsArrayBufferSliceToImmutable = array_ops.qjsArrayBufferSliceToImmutable;
pub const qjsArrayBufferSpeciesConstructor = array_ops.qjsArrayBufferSpeciesConstructor;
pub const qjsArrayBufferTransfer = array_ops.qjsArrayBufferTransfer;
pub const qjsArrayBufferTransferToImmutable = array_ops.qjsArrayBufferTransferToImmutable;
pub const qjsArrayByCopyCall = array_ops.qjsArrayByCopyCall;
pub const qjsArrayCopyWithinCall = array_ops.qjsArrayCopyWithinCall;
pub const qjsArrayFillCall = array_ops.qjsArrayFillCall;
pub const qjsArrayFlatCall = array_ops.qjsArrayFlatCall;
pub const qjsArrayForEachCall = array_ops.qjsArrayForEachCall;
pub const qjsArrayFromArrayLike = array_ops.qjsArrayFromArrayLike;
pub const qjsArrayFromCall = array_ops.qjsArrayFromCall;
pub const qjsArrayFromIteratorLike = array_ops.qjsArrayFromIteratorLike;
pub const qjsArrayIterationCall = array_ops.qjsArrayIterationCall;
pub const qjsArrayIteratorMethod = array_ops.qjsArrayIteratorMethod;
pub const qjsArrayIteratorMethodRecord = array_ops.qjsArrayIteratorMethodRecord;
pub const qjsArrayIteratorNext = array_ops.qjsArrayIteratorNext;
pub const qjsArrayIteratorValue = array_ops.qjsArrayIteratorValue;
pub const qjsArrayJoinCall = array_ops.qjsArrayJoinCall;
pub const qjsArrayLastIndexSparseLarge = array_ops.qjsArrayLastIndexSparseLarge;
pub const qjsArrayMapCall = array_ops.qjsArrayMapCall;
pub const qjsArrayMapSimpleNumericArg0DefaultSpeciesFastCall = array_ops.qjsArrayMapSimpleNumericArg0DefaultSpeciesFastCall;
pub const qjsArrayMethodFastCall = array_ops.qjsArrayMethodFastCall;
pub const qjsArrayOfCall = array_ops.qjsArrayOfCall;
pub const qjsArrayPopCall = array_ops.qjsArrayPopCall;
pub const qjsArrayPrototypeNativeRecord = array_ops.qjsArrayPrototypeNativeRecord;
pub const qjsArrayPushCall = array_ops.qjsArrayPushCall;
pub const qjsArrayReduceCall = array_ops.qjsArrayReduceCall;
pub const qjsArrayReduceRightSparseLarge = array_ops.qjsArrayReduceRightSparseLarge;
pub const qjsArrayReverseCall = array_ops.qjsArrayReverseCall;
pub const qjsArrayShiftCall = array_ops.qjsArrayShiftCall;
pub const qjsArraySliceCall = array_ops.qjsArraySliceCall;
pub const qjsArraySortCall = array_ops.qjsArraySortCall;
pub const qjsArraySpliceCall = array_ops.qjsArraySpliceCall;
pub const qjsArrayUnshiftCall = array_ops.qjsArrayUnshiftCall;
pub const qjsArrayUnshiftSparseLarge = array_ops.qjsArrayUnshiftSparseLarge;
pub const qjsCanFastJoinPrimitive = array_ops.qjsCanFastJoinPrimitive;
pub const qjsCreateArrayDataOrTypedArrayElement = array_ops.qjsCreateArrayDataOrTypedArrayElement;
pub const qjsDenseArrayMapSimpleNumericArg0 = array_ops.qjsDenseArrayMapSimpleNumericArg0;
pub const qjsFastDensePrimitiveArrayPop = array_ops.qjsFastDensePrimitiveArrayPop;
pub const qjsFastDensePrimitiveArrayJoin = array_ops.qjsFastDensePrimitiveArrayJoin;
pub const qjsGeneratorSlice = array_ops.qjsGeneratorSlice;
pub const qjsIteratorZipFlattenableRecord = array_ops.qjsIteratorZipFlattenableRecord;
pub const qjsObjectEntryArrayValue = array_ops.qjsObjectEntryArrayValue;
pub const qjsRelativeSliceIndex = array_ops.qjsRelativeSliceIndex;
pub const qjsSharedArrayBufferAccessor = array_ops.qjsSharedArrayBufferAccessor;
pub const qjsSharedArrayBufferGrow = array_ops.qjsSharedArrayBufferGrow;
pub const qjsTypedArrayAccessor = array_ops.qjsTypedArrayAccessor;
pub const qjsTypedArrayArrayBufferPrototypeVm = array_ops.qjsTypedArrayArrayBufferPrototypeVm;
pub const qjsTypedArrayByCopyCall = array_ops.qjsTypedArrayByCopyCall;
pub const qjsTypedArrayByCopyCoerceValue = array_ops.qjsTypedArrayByCopyCoerceValue;
pub const qjsTypedArrayConstructArrayLikeOwnDataFast = array_ops.qjsTypedArrayConstructArrayLikeOwnDataFast;
pub const qjsTypedArrayConstructArrayLikeVm = array_ops.qjsTypedArrayConstructArrayLikeVm;
pub const qjsTypedArrayConstructBufferVm = array_ops.qjsTypedArrayConstructBufferVm;
pub const qjsTypedArrayConstructFromIterable = array_ops.qjsTypedArrayConstructFromIterable;
pub const qjsTypedArrayConstructLengthVm = array_ops.qjsTypedArrayConstructLengthVm;
pub const qjsTypedArrayConstructToIndex = array_ops.qjsTypedArrayConstructToIndex;
pub const qjsTypedArrayConstructVm = array_ops.qjsTypedArrayConstructVm;
pub const qjsTypedArrayConstructorName = array_ops.qjsTypedArrayConstructorName;
pub const qjsTypedArrayConstructorPrototypeVm = array_ops.qjsTypedArrayConstructorPrototypeVm;
pub const qjsTypedArrayCreateSameType = array_ops.qjsTypedArrayCreateSameType;
pub const qjsTypedArrayCreateWithLength = array_ops.qjsTypedArrayCreateWithLength;
pub const qjsTypedArrayFromArrayLikeSource = array_ops.qjsTypedArrayFromArrayLikeSource;
pub const qjsTypedArrayFromIteratorValue = array_ops.qjsTypedArrayFromIteratorValue;
pub const qjsTypedArrayFromStaticCall = array_ops.qjsTypedArrayFromStaticCall;
pub const qjsTypedArrayMapFilter = array_ops.qjsTypedArrayMapFilter;
pub const qjsTypedArrayOfStaticCall = array_ops.qjsTypedArrayOfStaticCall;
pub const qjsTypedArraySetCall = array_ops.qjsTypedArraySetCall;
pub const qjsTypedArraySetElementValue = array_ops.qjsTypedArraySetElementValue;
pub const qjsTypedArraySliceSubarrayCall = array_ops.qjsTypedArraySliceSubarrayCall;
pub const qjsTypedArrayValidateConstructArgsPreAllocate = array_ops.qjsTypedArrayValidateConstructArgsPreAllocate;
pub const qjsUint8ArrayCodecCall = array_ops.qjsUint8ArrayCodecCall;
pub const qjsWorkerPopMessage = array_ops.qjsWorkerPopMessage;
pub const regExpLegacyNoCaptureSliceValue = array_ops.regExpLegacyNoCaptureSliceValue;
pub const simpleCaptureAtomsKnownDisjoint = array_ops.simpleCaptureAtomsKnownDisjoint;
pub const simpleClassPredicatesKnownDisjoint = array_ops.simpleClassPredicatesKnownDisjoint;
pub const stableArraySortEntries = array_ops.stableArraySortEntries;
pub const stableSortTieBreak = array_ops.stableSortTieBreak;
pub const throwRegExpAccessorTypeError = array_ops.throwRegExpAccessorTypeError;
pub const toIntegerOrInfinityForArrayByCopy = array_ops.toIntegerOrInfinityForArrayByCopy;
pub const toIntegerOrInfinityForArrayMethod = array_ops.toIntegerOrInfinityForArrayMethod;
pub const tryFuseTypedArrayConstructLengthPrint = array_ops.tryFuseTypedArrayConstructLengthPrint;
pub const tryFuseTypedArrayFromArrayBufferConstructorSequence = array_ops.tryFuseTypedArrayFromArrayBufferConstructorSequence;
pub const typedArrayArrayLikeOwnDataFastPathUsable = array_ops.typedArrayArrayLikeOwnDataFastPathUsable;
pub const typedArrayCanonicalDelete = array_ops.typedArrayCanonicalDelete;
pub const typedArrayCanonicalGet = array_ops.typedArrayCanonicalGet;
pub const typedArrayCanonicalHas = array_ops.typedArrayCanonicalHas;
pub const typedArrayCanonicalNumericIndex = builtins.buffer.typedArrayCanonicalNumericIndex;
pub const typedArrayCanonicalOwnDescriptor = array_ops.typedArrayCanonicalOwnDescriptor;
pub const typedArrayCanonicalSet = array_ops.typedArrayCanonicalSet;
pub const typedArrayConstructorForObject = array_ops.typedArrayConstructorForObject;
pub const typedArrayConstructorObject = array_ops.typedArrayConstructorObject;
pub const typedArrayDefaultSortCompare = array_ops.typedArrayDefaultSortCompare;
pub const typedArrayDefineOwnPropertyVm = array_ops.typedArrayDefineOwnPropertyVm;
pub const typedArrayNameFromKind = array_ops.typedArrayNameFromKind;
pub const typedArrayOwnKeys = array_ops.typedArrayOwnKeys;
pub const typedArrayPrototypeSet = array_ops.typedArrayPrototypeSet;
pub const typedArrayReflectSetReceiverOwn = array_ops.typedArrayReflectSetReceiverOwn;
pub const typedArraySpeciesConstructorForObject = array_ops.typedArraySpeciesConstructorForObject;
pub const typedArrayStaticMethodId = array_ops.typedArrayStaticMethodId;
pub const uint8ArrayBase64Alphabet = array_ops.uint8ArrayBase64Alphabet;
pub const uint8ArrayBase64LastChunkHandling = array_ops.uint8ArrayBase64LastChunkHandling;
pub const uint8ArrayCodecResult = array_ops.uint8ArrayCodecResult;
pub const uint8ArrayConstructorPrototypeObject = array_ops.uint8ArrayConstructorPrototypeObject;
pub const uint8ArrayOmitPadding = array_ops.uint8ArrayOmitPadding;
pub const uint8ArrayViewBytes = array_ops.uint8ArrayViewBytes;
pub const unshiftMoveIndex = array_ops.unshiftMoveIndex;
pub const verifyArrayLikeLengthSet = array_ops.verifyArrayLikeLengthSet;
pub const writeUint8ArrayPrefix = array_ops.writeUint8ArrayPrefix;

pub const promise_ops = @import("promise_ops.zig");
pub const AsyncDisposableStackMethod = promise_ops.AsyncDisposableStackMethod;
pub const PreparedPromiseReactionJobs = promise_ops.PreparedPromiseReactionJobs;
pub const PreparedPromiseReactionJobsRoot = promise_ops.PreparedPromiseReactionJobsRoot;
pub const PromiseCapabilityVm = promise_ops.PromiseCapabilityVm;
pub const PromiseCombinatorCallbackMode = promise_ops.PromiseCombinatorCallbackMode;
pub const PromiseCombinatorMode = promise_ops.PromiseCombinatorMode;
pub const PromiseFinallyCallbackMode = promise_ops.PromiseFinallyCallbackMode;
pub const PromiseRejectionReason = promise_ops.PromiseRejectionReason;
pub const PromiseResolvingPairVm = promise_ops.PromiseResolvingPairVm;
pub const PromiseStaticMode = promise_ops.PromiseStaticMode;
pub const asyncDisposableStackMethodFromMarker = promise_ops.asyncDisposableStackMethodFromMarker;
pub const asyncDisposableStackReceiver = promise_ops.asyncDisposableStackReceiver;
pub const asyncFunctionPrototypeFromGlobal = promise_ops.asyncFunctionPrototypeFromGlobal;
pub const asyncGeneratorFulfilledIteratorResult = promise_ops.asyncGeneratorFulfilledIteratorResult;
pub const asyncGeneratorFunctionPrototypeFromGlobal = promise_ops.asyncGeneratorFunctionPrototypeFromGlobal;
pub const asyncGeneratorIteratorResultFromPromise = promise_ops.asyncGeneratorIteratorResultFromPromise;
pub const asyncGeneratorPrototypeFromGlobal = promise_ops.asyncGeneratorPrototypeFromGlobal;
pub const asyncGeneratorRejectedTypeError = promise_ops.asyncGeneratorRejectedTypeError;
pub const asyncIteratorPrototypeFromGlobal = promise_ops.asyncIteratorPrototypeFromGlobal;
pub const atomicsDestroyAsyncWaiter = promise_ops.atomicsDestroyAsyncWaiter;
pub const atomicsLinkAsyncWaiter = promise_ops.atomicsLinkAsyncWaiter;
pub const atomicsSettleAsyncWaiter = promise_ops.atomicsSettleAsyncWaiter;
pub const atomicsWaitAsyncResult = promise_ops.atomicsWaitAsyncResult;
pub const awaitPendingPromise = promise_ops.awaitPendingPromise;
pub const awaitThenableValue = promise_ops.awaitThenableValue;
pub const clearHandledRejectionException = promise_ops.clearHandledRejectionException;
pub const closeForAwaitIteratorForPendingError = promise_ops.closeForAwaitIteratorForPendingError;
pub const closeForAwaitIteratorFromVm = promise_ops.closeForAwaitIteratorFromVm;
pub const constructAsyncFunctionFromSource = promise_ops.constructAsyncFunctionFromSource;
pub const constructAsyncGeneratorFunctionFromSource = promise_ops.constructAsyncGeneratorFunctionFromSource;
pub const createPromiseResolvingFunction = promise_ops.createPromiseResolvingFunction;
pub const createPromiseResolvingPair = promise_ops.createPromiseResolvingPair;
pub const createPromiseResolvingState = promise_ops.createPromiseResolvingState;
pub const defineAsyncGeneratorDataMethod = promise_ops.defineAsyncGeneratorDataMethod;
pub const drainPendingPromiseJobs = promise_ops.drainPendingPromiseJobs;
pub const enqueuePendingPromiseJob = promise_ops.enqueuePendingPromiseJob;
pub const finishAwaitedPromise = promise_ops.finishAwaitedPromise;
pub const installAsyncGeneratorPrototypeProperties = promise_ops.installAsyncGeneratorPrototypeProperties;
pub const isAsyncGeneratorPrototypeMethod = promise_ops.isAsyncGeneratorPrototypeMethod;
pub const isAsyncGeneratorReceiver = promise_ops.isAsyncGeneratorReceiver;
pub const parameterSourceContainsAwait = promise_ops.parameterSourceContainsAwait;
pub const promisePrototypeFromGlobal = promise_ops.promisePrototypeFromGlobal;
pub const promiseRejectionReason = promise_ops.promiseRejectionReason;
pub const qjsAppendPromiseReaction = promise_ops.qjsAppendPromiseReaction;
pub const qjsAsyncDisposableStackAdopt = promise_ops.qjsAsyncDisposableStackAdopt;
pub const qjsAsyncDisposableStackAwaitValue = promise_ops.qjsAsyncDisposableStackAwaitValue;
pub const qjsAsyncDisposableStackConstructWithPrototype = promise_ops.qjsAsyncDisposableStackConstructWithPrototype;
pub const qjsAsyncDisposableStackContinuation = promise_ops.qjsAsyncDisposableStackContinuation;
pub const qjsAsyncDisposableStackContinuationCall = promise_ops.qjsAsyncDisposableStackContinuationCall;
pub const qjsAsyncDisposableStackContinue = promise_ops.qjsAsyncDisposableStackContinue;
pub const qjsAsyncDisposableStackContinueOrReject = promise_ops.qjsAsyncDisposableStackContinueOrReject;
pub const qjsAsyncDisposableStackDefer = promise_ops.qjsAsyncDisposableStackDefer;
pub const qjsAsyncDisposableStackDisposeAsync = promise_ops.qjsAsyncDisposableStackDisposeAsync;
pub const qjsAsyncDisposableStackMethodCall = promise_ops.qjsAsyncDisposableStackMethodCall;
pub const qjsAsyncDisposableStackMove = promise_ops.qjsAsyncDisposableStackMove;
pub const qjsAsyncDisposableStackRecordError = promise_ops.qjsAsyncDisposableStackRecordError;
pub const qjsAsyncDisposableStackRejectStored = promise_ops.qjsAsyncDisposableStackRejectStored;
pub const qjsAsyncDisposableStackResolveStored = promise_ops.qjsAsyncDisposableStackResolveStored;
pub const qjsAsyncDisposableStackStoreCapability = promise_ops.qjsAsyncDisposableStackStoreCapability;
pub const qjsAsyncDisposableStackUse = promise_ops.qjsAsyncDisposableStackUse;
pub const qjsAsyncDisposeResource = promise_ops.qjsAsyncDisposeResource;
pub const qjsAsyncFromSyncIteratorContinuation = promise_ops.qjsAsyncFromSyncIteratorContinuation;
pub const qjsAsyncFromSyncIteratorMethodCall = promise_ops.qjsAsyncFromSyncIteratorMethodCall;
pub const qjsAsyncFromSyncIteratorNext = promise_ops.qjsAsyncFromSyncIteratorNext;
pub const qjsAsyncFromSyncIteratorReturn = promise_ops.qjsAsyncFromSyncIteratorReturn;
pub const qjsAsyncFromSyncIteratorUnwrap = promise_ops.qjsAsyncFromSyncIteratorUnwrap;
pub const qjsAsyncFromSyncIteratorUnwrapCall = promise_ops.qjsAsyncFromSyncIteratorUnwrapCall;
pub const qjsAsyncFunctionAwait = promise_ops.qjsAsyncFunctionAwait;
pub const qjsAsyncFunctionAwaitOrReject = promise_ops.qjsAsyncFunctionAwaitOrReject;
pub const qjsAsyncFunctionClearPromise = promise_ops.qjsAsyncFunctionClearPromise;
pub const qjsAsyncFunctionResumeCallback = promise_ops.qjsAsyncFunctionResumeCallback;
pub const qjsAsyncFunctionResumeCallbackCall = promise_ops.qjsAsyncFunctionResumeCallbackCall;
pub const qjsAsyncFunctionRunAndSettle = promise_ops.qjsAsyncFunctionRunAndSettle;
pub const qjsAsyncFunctionRunState = promise_ops.qjsAsyncFunctionRunState;
pub const qjsAsyncFunctionSettle = promise_ops.qjsAsyncFunctionSettle;
pub const qjsAsyncFunctionStart = promise_ops.qjsAsyncFunctionStart;
pub const qjsAsyncIteratorAsyncDispose = promise_ops.qjsAsyncIteratorAsyncDispose;
pub const qjsAtomicsWaitAsync = promise_ops.qjsAtomicsWaitAsync;
pub const qjsAtomicsWaitAsyncPromise = promise_ops.qjsAtomicsWaitAsyncPromise;
pub const qjsDefaultPromiseCapability = promise_ops.qjsDefaultPromiseCapability;
pub const qjsPerformPromiseThen = promise_ops.qjsPerformPromiseThen;
pub const qjsPreparePromiseReactionJobs = promise_ops.qjsPreparePromiseReactionJobs;
pub const qjsPromiseCapability = promise_ops.qjsPromiseCapability;
pub const qjsPromiseCapabilityExecutorCall = promise_ops.qjsPromiseCapabilityExecutorCall;
pub const qjsPromiseCatchGeneric = promise_ops.qjsPromiseCatchGeneric;
pub const qjsPromiseCombinatorCall = promise_ops.qjsPromiseCombinatorCall;
pub const qjsPromiseCombinatorCallback = promise_ops.qjsPromiseCombinatorCallback;
pub const qjsPromiseCombinatorElementCall = promise_ops.qjsPromiseCombinatorElementCall;
pub const qjsPromiseCombinatorState = promise_ops.qjsPromiseCombinatorState;
pub const qjsPromiseConstruct = promise_ops.qjsPromiseConstruct;
pub const qjsPromiseConstructWithPrototype = promise_ops.qjsPromiseConstructWithPrototype;
pub const qjsPromiseConstructorRealmGlobal = promise_ops.qjsPromiseConstructorRealmGlobal;
pub const qjsPromiseDefaultConstructor = promise_ops.qjsPromiseDefaultConstructor;
pub const qjsPromiseFinally = promise_ops.qjsPromiseFinally;
pub const qjsPromiseFinallyCallback = promise_ops.qjsPromiseFinallyCallback;
pub const qjsPromiseFinallyCallbackCall = promise_ops.qjsPromiseFinallyCallbackCall;
pub const qjsPromiseKeyedCombinatorCall = promise_ops.qjsPromiseKeyedCombinatorCall;
pub const qjsPromiseKeyedCombinatorState = promise_ops.qjsPromiseKeyedCombinatorState;
pub const qjsPromiseKeyedResult = promise_ops.qjsPromiseKeyedResult;
pub const qjsPromiseReactionJob = promise_ops.qjsPromiseReactionJob;
pub const qjsPromiseReactionJobCall = promise_ops.qjsPromiseReactionJobCall;
pub const qjsPromiseReactionRecord = promise_ops.qjsPromiseReactionRecord;
pub const qjsPromiseRejectCapability = promise_ops.qjsPromiseRejectCapability;
pub const qjsPromiseRejectCapabilityForError = promise_ops.qjsPromiseRejectCapabilityForError;
pub const qjsPromiseResolveCapability = promise_ops.qjsPromiseResolveCapability;
pub const qjsPromiseResolveIdentity = promise_ops.qjsPromiseResolveIdentity;
pub const qjsPromiseResolvingFunctionCall = promise_ops.qjsPromiseResolvingFunctionCall;
pub const qjsPromiseSetArrayIndex = promise_ops.qjsPromiseSetArrayIndex;
pub const qjsPromiseSettleValue = promise_ops.qjsPromiseSettleValue;
pub const qjsPromiseSettlementRecord = promise_ops.qjsPromiseSettlementRecord;
pub const qjsPromiseSpeciesConstructor = promise_ops.qjsPromiseSpeciesConstructor;
pub const qjsPromiseStaticBuiltinCallee = promise_ops.qjsPromiseStaticBuiltinCallee;
pub const qjsPromiseStaticCall = promise_ops.qjsPromiseStaticCall;
pub const qjsPromiseStaticMode = promise_ops.qjsPromiseStaticMode;
pub const qjsPromiseThen = promise_ops.qjsPromiseThen;
pub const qjsPromiseThenableJob = promise_ops.qjsPromiseThenableJob;
pub const qjsPromiseThenableJobCall = promise_ops.qjsPromiseThenableJobCall;
pub const qjsPromiseThenableJobPending = promise_ops.qjsPromiseThenableJobPending;
pub const qjsQueuePromiseReactions = promise_ops.qjsQueuePromiseReactions;
pub const qjsReflectConstructResolveBound = promise_ops.qjsReflectConstructResolveBound;
pub const qjsSettlePendingThenableJobs = promise_ops.qjsSettlePendingThenableJobs;
pub const qjsUsingAddAsyncResource = promise_ops.qjsUsingAddAsyncResource;
pub const qjsUsingCreateAsyncDisposableStack = promise_ops.qjsUsingCreateAsyncDisposableStack;
pub const qjsUsingDisposeAsyncStack = promise_ops.qjsUsingDisposeAsyncStack;
pub const qjsUsingDisposeAsyncStackForThrow = promise_ops.qjsUsingDisposeAsyncStackForThrow;
pub const qjsWorkerHasActiveAsyncDependency = promise_ops.qjsWorkerHasActiveAsyncDependency;
pub const qjsWorkerRecordHasActiveAsyncDependency = promise_ops.qjsWorkerRecordHasActiveAsyncDependency;
pub const rejectModuleNamespaceSuperSet = promise_ops.rejectModuleNamespaceSuperSet;
pub const settlePendingPromiseReaction = promise_ops.settlePendingPromiseReaction;

pub const proxy_ops = @import("object_ops.zig");
pub const callProxyApply = proxy_ops.callProxyApply;
pub const completeProxyDescriptor = proxy_ops.completeProxyDescriptor;
pub const constructProxy = proxy_ops.constructProxy;
pub const firstProxyInPrototypeSetPath = proxy_ops.firstProxyInPrototypeSetPath;
pub const getProxyProperty = proxy_ops.getProxyProperty;
pub const isCompatibleProxyDescriptor = proxy_ops.isCompatibleProxyDescriptor;
pub const isRevokedProxy = proxy_ops.isRevokedProxy;
pub const proxyAwareIsExtensible = proxy_ops.proxyAwareIsExtensible;
pub const proxyAwareOwnPropertyDescriptor = proxy_ops.proxyAwareOwnPropertyDescriptor;
pub const proxyAwarePreventExtensions = proxy_ops.proxyAwarePreventExtensions;
pub const proxyAwareSetPrototypeOf = proxy_ops.proxyAwareSetPrototypeOf;
pub const proxyCreateDataPropertyOrThrow = proxy_ops.proxyCreateDataPropertyOrThrow;
pub const proxyDefineOwnProperty = proxy_ops.proxyDefineOwnProperty;
pub const proxyDefineValueForReflectSet = proxy_ops.proxyDefineValueForReflectSet;
pub const proxySetTrapForErrorStackSetter = proxy_ops.proxySetTrapForErrorStackSetter;
pub const proxySetValueProperty = proxy_ops.proxySetValueProperty;
pub const proxyTargetIsCallable = proxy_ops.proxyTargetIsCallable;
pub const proxyTargetIsCallableObject = proxy_ops.proxyTargetIsCallableObject;
pub const proxyTargetIsConstructor = proxy_ops.proxyTargetIsConstructor;
pub const proxyTrapKeyValue = proxy_ops.proxyTrapKeyValue;
pub const validateProxyGetResult = proxy_ops.validateProxyGetResult;
pub const validateProxyHasResult = proxy_ops.validateProxyHasResult;
pub const validateProxyOwnKeysResult = proxy_ops.validateProxyOwnKeysResult;
pub const validateProxySetResult = proxy_ops.validateProxySetResult;

pub const object_ops = @import("object_ops.zig");
pub const FastUnicodePropertyPredicate = object_ops.FastUnicodePropertyPredicate;
pub const OwnPropertyKeyFilter = object_ops.OwnPropertyKeyFilter;
pub const PendingPropertyDescriptor = object_ops.PendingPropertyDescriptor;
pub const PropertyEscapePattern = object_ops.PropertyEscapePattern;
pub const UnicodePropertyRunPattern = object_ops.UnicodePropertyRunPattern;
pub const WorkerObjectInitError = object_ops.WorkerObjectInitError;
pub const anchoredBinaryPropertyName = object_ops.anchoredBinaryPropertyName;
pub const appendObjectGroupByValue = object_ops.appendObjectGroupByValue;
pub const appendPrivateBoundNamesFromObject = object_ops.appendPrivateBoundNamesFromObject;
pub const atomPropertyName = object_ops.atomPropertyName;
pub const atomicsBufferObject = object_ops.atomicsBufferObject;
pub const bytecodeFunctionObjectTag = object_ops.bytecodeFunctionObjectTag;
pub const cachedRealmObject = object_ops.cachedRealmObject;
pub const callObjectToPrimitiveMethod = object_ops.callObjectToPrimitiveMethod;
pub const callSitePrototypeFromGlobal = object_ops.callSitePrototypeFromGlobal;
pub const callableObjectFromValue = object_ops.callableObjectFromValue;
pub const capturedArgumentsObject = object_ops.capturedArgumentsObject;
pub const constructCollectionWithPrototypeFromVm = object_ops.constructCollectionWithPrototypeFromVm;
pub const constructPrimitiveWrapperWithPrototype = object_ops.constructPrimitiveWrapperWithPrototype;
pub const constructorPrototypeFromGlobal = object_ops.constructorPrototypeFromGlobal;
pub const constructorPrototypeFromGlobalAtom = object_ops.constructorPrototypeFromGlobalAtom;
pub const constructorPrototypeObject = object_ops.constructorPrototypeObject;
pub const copyRealmPrototypeKeys = object_ops.copyRealmPrototypeKeys;
pub const createArgumentsObject = object_ops.createArgumentsObject;
pub const createBytecodeFunctionObject = object_ops.createBytecodeFunctionObject;
pub const createCallSiteObject = object_ops.createCallSiteObject;
pub const createDataPropertyOrThrow = object_ops.createDataPropertyOrThrow;
pub const createGeneratorObject = object_ops.createGeneratorObject;
pub const currentArrowFunctionObject = object_ops.currentArrowFunctionObject;
pub const defineClassFieldDataProperty = object_ops.defineClassFieldDataProperty;
pub const defineDataProperty = object_ops.defineDataProperty;
pub const defineErrorStackDataProperty = object_ops.defineErrorStackDataProperty;
pub const defineFreshNonIndexDataProperty = object_ops.defineFreshNonIndexDataProperty;
pub const defineFunctionNameProperty = object_ops.defineFunctionNameProperty;
pub const defineRegExpGroupsProperty = object_ops.defineRegExpGroupsProperty;
pub const defineRegExpGroupsPropertyFromValue = object_ops.defineRegExpGroupsPropertyFromValue;
pub const defineRegExpIndicesGroupsProperty = object_ops.defineRegExpIndicesGroupsProperty;
pub const defineValueProperty = object_ops.defineValueProperty;
pub const deleteValueProperty = object_ops.deleteValueProperty;
pub const deleteValuePropertyOrThrow = object_ops.deleteValuePropertyOrThrow;
pub const descriptorObjectFromDescriptor = object_ops.descriptorObjectFromDescriptor;
pub const directEvalCallerAllowsSuperProperty = object_ops.directEvalCallerAllowsSuperProperty;
pub const directEvalWithObject = object_ops.directEvalWithObject;
pub const dynamicFunctionDefaultPrototype = object_ops.dynamicFunctionDefaultPrototype;
pub const dynamicFunctionNewTargetPrototype = object_ops.dynamicFunctionNewTargetPrototype;
pub const fastUnicodePropertyPredicate = object_ops.fastUnicodePropertyPredicate;
pub const findPropertyDescriptor = object_ops.findPropertyDescriptor;
pub const frameArgumentsObject = object_ops.frameArgumentsObject;
pub const frameArgumentsObjectForSpecialObject = object_ops.frameArgumentsObjectForSpecialObject;
pub const functionBytecodeUsesArgumentsSpecialObject = object_ops.functionBytecodeUsesArgumentsSpecialObject;
pub const functionCallerArgumentsProperty = object_ops.functionCallerArgumentsProperty;
pub const functionObjectFromValue = object_ops.functionObjectFromValue;
pub const functionPrototypeFromGlobal = object_ops.functionPrototypeFromGlobal;
pub const generatorFunctionPrototypeFromGlobal = object_ops.generatorFunctionPrototypeFromGlobal;
pub const generatorObjectPrototype = object_ops.generatorObjectPrototype;
pub const generatorPrototypeFromGlobal = object_ops.generatorPrototypeFromGlobal;
pub const getAccessorDescriptorValue = object_ops.getAccessorDescriptorValue;
pub const getFastNumberPrimitiveDataProperty = object_ops.getFastNumberPrimitiveDataProperty;
pub const getMethodPropertyForOrdinaryToPrimitive = object_ops.getMethodPropertyForOrdinaryToPrimitive;
pub const getNumberPrototypeMethodId = object_ops.getNumberPrototypeMethodId;
pub const getPrimitiveProperty = object_ops.getPrimitiveProperty;
pub const getPrivateValueProperty = object_ops.getPrivateValueProperty;
pub const getPrototypeMethod = object_ops.getPrototypeMethod;
pub const getPrototypeMethodWithFallback = object_ops.getPrototypeMethodWithFallback;
pub const getPrototypePropertyValue = object_ops.getPrototypePropertyValue;
pub const getSuperPropertyValue = object_ops.getSuperPropertyValue;
pub const getValueProperty = object_ops.getValueProperty;
pub const getValuePropertyWithReceiver = object_ops.getValuePropertyWithReceiver;
pub const hasPropertyForWith = object_ops.hasPropertyForWith;
pub const hasValueProperty = object_ops.hasValueProperty;
pub const importMetaObject = object_ops.importMetaObject;
pub const indexedExoticHasProperty = object_ops.indexedExoticHasProperty;
pub const installFunctionPrototypeThrowTypeErrorAccessors = object_ops.installFunctionPrototypeThrowTypeErrorAccessors;
pub const installGeneratorPrototypeProperties = object_ops.installGeneratorPrototypeProperties;
pub const internalSpecialObjectValue = object_ops.internalSpecialObjectValue;
pub const isAnchoredBinaryPropertySource = object_ops.isAnchoredBinaryPropertySource;
pub const isObjectPrototypeNativeRecord = object_ops.isObjectPrototypeNativeRecord;
pub const isRuntimeSupportedBinaryPropertyName = object_ops.isRuntimeSupportedBinaryPropertyName;
pub const isSameRealmRegExpPrototypeGetter = object_ops.isSameRealmRegExpPrototypeGetter;
pub const isStandardNumberPrototypeMethodAtom = object_ops.isStandardNumberPrototypeMethodAtom;
pub const isThrowTypeErrorIntrinsicObject = object_ops.isThrowTypeErrorIntrinsicObject;
pub const iteratorIsOnIteratorPrototypeChain = object_ops.iteratorIsOnIteratorPrototypeChain;
pub const iteratorPrototypeFromGlobal = object_ops.iteratorPrototypeFromGlobal;
pub const objectFromValue = object_ops.objectFromValue;
pub const objectHasImmutablePrototype = object_ops.objectHasImmutablePrototype;
pub const objectHasNonEmptyName = object_ops.objectHasNonEmptyName;
pub const objectHasRegExpInternalSlots = object_ops.objectHasRegExpInternalSlots;
pub const objectIsExtensibleForIntegrity = object_ops.objectIsExtensibleForIntegrity;
pub const objectPrototypeFromGlobal = object_ops.objectPrototypeFromGlobal;
pub const objectRealmGlobal = object_ops.objectRealmGlobal;
pub const objectRestKeyExcluded = object_ops.objectRestKeyExcluded;
pub const objectRestOwnKeys = object_ops.objectRestOwnKeys;
pub const objectRestOwnPropertyDescriptor = object_ops.objectRestOwnPropertyDescriptor;
pub const ordinaryHasValueProperty = object_ops.ordinaryHasValueProperty;
pub const ownDataOrAutoInitPropertyValue = object_ops.ownDataOrAutoInitPropertyValue;
pub const primitiveObjectForAccess = object_ops.primitiveObjectForAccess;
pub const primitivePrototypeThisValue = object_ops.primitivePrototypeThisValue;
pub const propertyAtomFromLengthIndex = object_ops.propertyAtomFromLengthIndex;
pub const propertyEscapePattern = object_ops.propertyEscapePattern;
pub const propertyIndexFromLengthKey = object_ops.propertyIndexFromLengthKey;
pub const qjsAggregateErrorConstructWithPrototype = object_ops.qjsAggregateErrorConstructWithPrototype;
pub const qjsConstructFinalizationRegistryWithPrototype = object_ops.qjsConstructFinalizationRegistryWithPrototype;
pub const qjsConstructWeakRefWithPrototype = object_ops.qjsConstructWeakRefWithPrototype;
pub const qjsDataViewConstructWithPrototype = object_ops.qjsDataViewConstructWithPrototype;
pub const qjsDatePrototypeMethod = object_ops.qjsDatePrototypeMethod;
pub const qjsDefinePropertyWithKind = object_ops.qjsDefinePropertyWithKind;
pub const qjsDescriptorFromObject = object_ops.qjsDescriptorFromObject;
pub const qjsDestructuringObjectRest = object_ops.qjsDestructuringObjectRest;
pub const qjsDisposableStackConstructWithPrototype = object_ops.qjsDisposableStackConstructWithPrototype;
pub const qjsErrorConstructWithPrototype = object_ops.qjsErrorConstructWithPrototype;
pub const qjsGetOwnPropertyDescriptorCall = object_ops.qjsGetOwnPropertyDescriptorCall;
pub const qjsGetOwnPropertyDescriptorsCall = object_ops.qjsGetOwnPropertyDescriptorsCall;
pub const qjsIteratorPrototype = object_ops.qjsIteratorPrototype;
pub const qjsIteratorPrototypeAccessor = object_ops.qjsIteratorPrototypeAccessor;
pub const qjsIteratorPrototypeAccessorSet = object_ops.qjsIteratorPrototypeAccessorSet;
pub const qjsIteratorPrototypeMethodCall = object_ops.qjsIteratorPrototypeMethodCall;
pub const qjsNumberPrototypeMethod = object_ops.qjsNumberPrototypeMethod;
pub const qjsObjectAssignCall = object_ops.qjsObjectAssignCall;
pub const qjsObjectAssignKeys = object_ops.qjsObjectAssignKeys;
pub const qjsObjectCallForNativeRecord = object_ops.qjsObjectCallForNativeRecord;
pub const qjsObjectCreateCall = object_ops.qjsObjectCreateCall;
pub const qjsObjectEnumerableOwnPropertiesCall = object_ops.qjsObjectEnumerableOwnPropertiesCall;
pub const qjsObjectFromEntriesCall = object_ops.qjsObjectFromEntriesCall;
pub const qjsObjectGetPrototypeOfCall = object_ops.qjsObjectGetPrototypeOfCall;
pub const qjsObjectGetPrototypeOfStep = object_ops.qjsObjectGetPrototypeOfStep;
pub const qjsObjectGetPrototypeOfValue = object_ops.qjsObjectGetPrototypeOfValue;
pub const qjsObjectGroupByCall = object_ops.qjsObjectGroupByCall;
pub const qjsObjectHasOwnCall = object_ops.qjsObjectHasOwnCall;
pub const qjsObjectIsExtensibleCall = object_ops.qjsObjectIsExtensibleCall;
pub const qjsObjectIsPrototypeOf = object_ops.qjsObjectIsPrototypeOf;
pub const qjsObjectOwnPropertyKeysCall = object_ops.qjsObjectOwnPropertyKeysCall;
pub const qjsObjectPreventExtensionsCall = object_ops.qjsObjectPreventExtensionsCall;
pub const qjsObjectProtoGetterCall = object_ops.qjsObjectProtoGetterCall;
pub const qjsObjectProtoSetterCall = object_ops.qjsObjectProtoSetterCall;
pub const qjsObjectPrototypeDefineAccessorCall = object_ops.qjsObjectPrototypeDefineAccessorCall;
pub const qjsObjectPrototypeLookupAccessorCall = object_ops.qjsObjectPrototypeLookupAccessorCall;
pub const qjsObjectPrototypeMethodFunctionPrototype = object_ops.qjsObjectPrototypeMethodFunctionPrototype;
pub const qjsObjectPrototypeOwnPropertyCall = object_ops.qjsObjectPrototypeOwnPropertyCall;
pub const qjsObjectSetIntegrityCall = object_ops.qjsObjectSetIntegrityCall;
pub const qjsObjectSetPrototypeOfCall = object_ops.qjsObjectSetPrototypeOfCall;
pub const qjsObjectTestIntegrityCall = object_ops.qjsObjectTestIntegrityCall;
pub const qjsObjectValueOfCall = object_ops.qjsObjectValueOfCall;
pub const qjsOptionalBoolDescriptorProperty = object_ops.qjsOptionalBoolDescriptorProperty;
pub const qjsPrimitivePrototypeMethod = object_ops.qjsPrimitivePrototypeMethod;
pub const qjsReflectDeletePropertyCall = object_ops.qjsReflectDeletePropertyCall;
pub const qjsReflectGetOwnPropertyDescriptorCall = object_ops.qjsReflectGetOwnPropertyDescriptorCall;
pub const qjsReflectGetPrototypeOfCall = object_ops.qjsReflectGetPrototypeOfCall;
pub const qjsReflectSetPrototypeOfCall = object_ops.qjsReflectSetPrototypeOfCall;
pub const qjsRegExpExecAnchoredPropertyFallback = object_ops.qjsRegExpExecAnchoredPropertyFallback;
pub const qjsRegExpExecPropertyFallback = object_ops.qjsRegExpExecPropertyFallback;
pub const qjsRegExpPrototypeMethodIsDefault = object_ops.qjsRegExpPrototypeMethodIsDefault;
pub const qjsSuppressedErrorConstructWithPrototype = object_ops.qjsSuppressedErrorConstructWithPrototype;
pub const qjsWorkerObjectId = object_ops.qjsWorkerObjectId;
pub const qjsWorkerParentObject = object_ops.qjsWorkerParentObject;
pub const readUnicodePropertyClassEscape = object_ops.readUnicodePropertyClassEscape;
pub const reflectConstructPrototypeVm = object_ops.reflectConstructPrototypeVm;
pub const reflectConstructRealmPrototype = object_ops.reflectConstructRealmPrototype;
pub const regExpExecPropertyIsDefault = object_ops.regExpExecPropertyIsDefault;
pub const regExpPrototypeFromGlobal = object_ops.regExpPrototypeFromGlobal;
pub const regexpSourceUsesZigPropertyFallback = object_ops.regexpSourceUsesZigPropertyFallback;
pub const remapPrivateAtomFromObject = object_ops.remapPrivateAtomFromObject;
pub const sameObjectIdentity = object_ops.sameObjectIdentity;
pub const setPrivateValueProperty = object_ops.setPrivateValueProperty;
pub const setSuperPropertyValue = object_ops.setSuperPropertyValue;
pub const setValueProperty = object_ops.setValueProperty;
pub const setValuePropertyStrict = object_ops.setValuePropertyStrict;
pub const setWithOwnDescriptor = object_ops.setWithOwnDescriptor;
pub const simpleUnicodePropertyRunTestFast = object_ops.simpleUnicodePropertyRunTestFast;
pub const tagIteratorWrapPrototypeMethod = object_ops.tagIteratorWrapPrototypeMethod;
pub const throwNullishComputedPropertyTypeError = object_ops.throwNullishComputedPropertyTypeError;
pub const throwNullishPropertyTypeError = object_ops.throwNullishPropertyTypeError;
pub const throwPrimitivePrototypeTypeError = object_ops.throwPrimitivePrototypeTypeError;
pub const toPropertyKeyAtom = object_ops.toPropertyKeyAtom;
pub const toPropertyKeyValue = object_ops.toPropertyKeyValue;
pub const unicodePropertyOnlyClassBody = object_ops.unicodePropertyOnlyClassBody;
pub const unicodePropertyOnlyClassSource = object_ops.unicodePropertyOnlyClassSource;
pub const unicodePropertyRunPattern = object_ops.unicodePropertyRunPattern;
pub const withObjectBindingValue = object_ops.withObjectBindingValue;
pub const wrapForValidIteratorPrototype = object_ops.wrapForValidIteratorPrototype;
pub const ensureLocalsCapacity = utils.ensureLocalsCapacity;
pub const ensureVarRefsCapacity = utils.ensureVarRefsCapacity;
pub const catchTargetFromMarker = utils.catchTargetFromMarker;

pub fn createForInIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    if (try createSimpleForInIterator(rt, object_value)) |simple| return simple;

    var iterator_val = core.JSValue.undefinedValue();
    var source_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &iterator_val },
        .{ .value = &source_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;
    defer source_val.free(rt);

    const iterator = try core.Object.create(rt, core.class.ids.for_in_iterator, null);
    errdefer core.Object.destroyFromHeader(rt, &iterator.header);
    iterator_val = iterator.value();

    var out_index: u32 = 0;

    if (!object_value.isNull() and !object_value.isUndefined()) {
        source_val = if (object_value.isObject()) object_value.dup() else try primitiveObjectForAccess(rt, global, object_value);
        var seen: []core.Atom = &.{};
        defer freeAtomList(rt, seen);
        var current: ?*core.Object = try property_ops.expectObject(source_val);
        const root = current;
        while (current) |object| {
            if (root != null and object == root.? and builtins.buffer.isTypedArrayObject(object)) {
                const length = builtins.buffer.typedArrayLength(rt, object) catch 0;
                var index: u32 = 0;
                while (index < length) : (index += 1) {
                    const key = core.atom.atomFromUInt32(index);
                    try appendAtom(rt, &seen, key);
                    const key_value = try rt.atoms.toStringValue(rt, key);
                    defer key_value.free(rt);
                    try iterator.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(key_value, true, true, true));
                    out_index += 1;
                }
            }
            const keys = try objectRestOwnKeys(ctx, output, global, object);
            defer core.Object.freeKeys(rt, keys);

            for (keys) |key| {
                if (rt.atoms.kind(key) == .symbol) continue;
                if (atomListContains(seen, key)) continue;
                try appendAtom(rt, &seen, key);
                if (object.moduleNamespaceOwnBindingValue(key)) |binding_value| {
                    defer binding_value.free(rt);
                    if (binding_value.isUninitialized()) return error.ReferenceError;
                }
                const desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, key, null, null) orelse continue;
                defer desc.destroy(rt);
                if (!(desc.enumerable orelse false)) continue;
                const key_value = try rt.atoms.toStringValue(rt, key);
                defer key_value.free(rt);
                try iterator.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(key_value, true, true, true));
                out_index += 1;
            }

            current = try qjsObjectGetPrototypeOfStep(ctx, output, global, object, null, null);
        }

        const source_key = try rt.internAtom("__source");
        defer rt.atoms.free(source_key);
        try iterator.defineOwnProperty(rt, source_key, core.Descriptor.data(source_val, true, false, true));
    }
    iterator.length = out_index;

    const index_key = try rt.internAtom("__index");
    defer rt.atoms.free(index_key);
    try iterator.defineOwnProperty(rt, index_key, core.Descriptor.data(core.JSValue.int32(0), true, true, true));
    return iterator.value();
}

pub fn createSimpleForInIterator(rt: *core.JSRuntime, object_value: core.JSValue) !?core.JSValue {
    if (object_value.isNull() or object_value.isUndefined()) return null;
    if (!object_value.isObject()) return null;
    const source = objectFromValue(object_value) orelse return null;
    if (!simpleForInRootCanUseFastPath(rt, source)) return null;
    const key_count = simpleForInEnumerableStringKeyCount(rt, source);
    const out_length = std.math.cast(u32, key_count) orelse return null;

    const iterator = try core.Object.create(rt, core.class.ids.for_in_iterator, null);
    errdefer core.Object.destroyFromHeader(rt, &iterator.header);
    if (key_count != 0) {
        const keys = try rt.memory.alloc(core.Atom, key_count);
        errdefer rt.memory.free(core.Atom, keys);
        var out_index: usize = 0;
        for (source.properties) |entry| {
            if (entry.flags.deleted or !entry.flags.enumerable) continue;
            if (rt.atoms.kind(entry.atom_id) != .string) continue;
            keys[out_index] = rt.atoms.dup(entry.atom_id);
            out_index += 1;
        }
        iterator.iteratorAtomKeysSlot().* = keys;
    }
    iterator.length = out_length;

    iterator.iteratorKindSlot().* = iter_vm.simple_for_in_iterator_kind;
    iterator.iteratorIndexSlot().* = 0;
    try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), object_value.dup());
    return iterator.value();
}

fn simpleForInEnumerableStringKeyCount(rt: *core.JSRuntime, source: *core.Object) usize {
    var count: usize = 0;
    for (source.properties) |entry| {
        if (entry.flags.deleted or !entry.flags.enumerable) continue;
        if (rt.atoms.kind(entry.atom_id) != .string) continue;
        count += 1;
    }
    return count;
}

pub fn simpleForInRootCanUseFastPath(rt: *core.JSRuntime, source: *core.Object) bool {
    if (source.class_id != core.class.ids.object or source.is_proxy or source.exotic != null or source.is_array) return false;
    if (builtins.buffer.isTypedArrayObject(source)) return false;
    if (source.arrayElements().len != 0) return false;
    for (source.properties) |entry| {
        if (entry.flags.deleted) continue;
        if (core.array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) != null) return false;
        const kind = rt.atoms.kind(entry.atom_id);
        if (kind != .string and kind != .symbol and kind != .private) return false;
    }

    var proto = source.getPrototype();
    while (proto) |object| : (proto = object.getPrototype()) {
        if (object.is_proxy or object.exotic != null) return false;
        if (builtins.buffer.isTypedArrayObject(object)) return false;
        if (object.arrayElements().len != 0) return false;
        for (object.properties) |entry| {
            if (entry.flags.deleted or !entry.flags.enumerable) continue;
            if (rt.atoms.kind(entry.atom_id) == .symbol or rt.atoms.kind(entry.atom_id) == .private) continue;
            return false;
        }
    }
    return true;
}

pub fn atomListContains(list: []const core.Atom, needle: core.Atom) bool {
    for (list) |atom_id| {
        if (atom_id == needle) return true;
    }
    return false;
}

pub fn appendAtom(rt: *core.JSRuntime, list: *[]core.Atom, atom_id: core.Atom) !void {
    const next = try rt.memory.alloc(core.Atom, list.len + 1);
    errdefer rt.memory.free(core.Atom, next);
    @memcpy(next[0..list.len], list.*);
    next[list.len] = rt.atoms.dup(atom_id);
    const old = list.*;
    list.* = next;
    if (old.len != 0) rt.memory.free(core.Atom, old);
}

pub fn freeAtomList(rt: *core.JSRuntime, list: []core.Atom) void {
    for (list) |atom_id| rt.atoms.free(atom_id);
    if (list.len != 0) rt.memory.free(core.Atom, list);
}

pub fn findForOfIteratorIndex(rt: *core.JSRuntime, stack: *const stack_mod.Stack) !usize {
    var index = stack.values.len;
    while (index > 0) {
        index -= 1;
        const value = stack.values[index];
        if (isIteratorLikeValue(rt, value)) return index;
    }
    return error.StackUnderflow;
}

pub fn isIteratorLikeValue(rt: *core.JSRuntime, value: core.JSValue) bool {
    const object = property_ops.expectObject(value) catch return false;
    if (object.cachedIteratorNext() != null) return true;
    const next_key = rt.internAtom("next") catch return false;
    defer rt.atoms.free(next_key);
    const next_value = object.getProperty(next_key);
    defer next_value.free(rt);
    return isCallableValue(next_value);
}

pub fn closeStackTopForOfIteratorForPendingError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *const stack_mod.Stack,
) !void {
    return closeStackTopForOfIteratorForPendingErrorInternal(ctx, output, global, stack, null);
}

pub fn closeStackTopForOfIteratorForPendingErrorWithFrame(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *const stack_mod.Stack,
    frame: *const frame_mod.Frame,
) !void {
    return closeStackTopForOfIteratorForPendingErrorInternal(ctx, output, global, stack, frame);
}

pub fn closeStackTopForOfIteratorForPendingErrorInternal(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *const stack_mod.Stack,
    frame: ?*const frame_mod.Frame,
) !void {
    const record_index = findTopClosableForOfRecordIndex(stack) orelse return;
    const iterator_value = stack.values[record_index].dup();
    defer iterator_value.free(ctx.runtime);
    if (property_ops.expectObject(iterator_value)) |object| {
        if (isDestructuringIteratorState(object)) return;
    } else |_| {}
    if (frame) |active_frame| {
        if (activeDestructuringStateTargetsIterator(stack.values, active_frame, iterator_value)) return;
    }

    const pending_exception = if (ctx.hasException()) ctx.takeException() else null;
    defer if (pending_exception) |value| value.free(ctx.runtime);
    closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
    if (ctx.hasException()) ctx.clearException();
    if (pending_exception) |value| _ = ctx.throwValue(value.dup());
}

pub fn findTopClosableForOfRecordIndex(stack: *const stack_mod.Stack) ?usize {
    if (stack.values.len < 3) return null;
    var index = stack.values.len - 3;
    while (true) {
        if (isForOfRecordAt(stack, index) and !hasCatchMarkerAboveForOfRecord(stack, index)) {
            return index;
        }
        if (index == 0) break;
        index -= 1;
    }
    return null;
}

pub fn isForOfRecordAt(stack: *const stack_mod.Stack, index: usize) bool {
    if (index + 2 >= stack.values.len) return false;
    return stack.values[index].isObject() and
        isCallableValue(stack.values[index + 1]) and
        stack.values[index + 2].isCatchOffset();
}

pub fn hasCatchMarkerAboveForOfRecord(stack: *const stack_mod.Stack, record_index: usize) bool {
    var index = record_index + 3;
    while (index < stack.values.len) : (index += 1) {
        if (stack.values[index].isCatchOffset()) return true;
    }
    return false;
}

pub fn activeDestructuringStateTargetsIterator(
    stack_values: []const core.JSValue,
    frame: *const frame_mod.Frame,
    iterator_value: core.JSValue,
) bool {
    return destructuringStateTargetsIteratorInValues(stack_values, iterator_value) or
        destructuringStateTargetsIteratorInValues(frame.locals, iterator_value) or
        destructuringStateTargetsIteratorInValues(frame.args, iterator_value) or
        destructuringStateTargetsIteratorInValues(frame.var_refs, iterator_value);
}

pub fn destructuringStateTargetsIteratorInValues(values: []const core.JSValue, iterator_value: core.JSValue) bool {
    for (values) |value| {
        const object = property_ops.expectObject(value) catch continue;
        if (!isDestructuringIteratorState(object)) continue;
        const target = (object.iteratorTargetSlot().*) orelse continue;
        if (sameObjectIdentity(target, iterator_value)) return true;
    }
    return false;
}

pub fn functionConstructorFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    if (global.getOwnDataObjectBorrowed(core.atom.ids.Function)) |constructor| return constructor;
    const function_value = global.getProperty(core.atom.ids.Function);
    defer function_value.free(rt);
    return property_ops.expectObject(function_value) catch null;
}

pub fn storeRealmValue(rt: *core.JSRuntime, global: *core.Object, slot: core.object.RealmValueSlot, value: core.JSValue) !void {
    const cached = try global.cachedRealmValueSlot(rt, slot);
    try global.setOptionalValueSlot(rt, cached, value.dup());
}

pub fn defineNativeDataMethod(rt: *core.JSRuntime, object: *core.Object, name: []const u8, length: i32) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const method = try builtins.function.nativeFunction(rt, name, length);
    defer method.free(rt);
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(method, true, false, true));
}

pub const stackValueFromTop = utils.stackValueFromTop;

pub fn toPrimitiveForAddition(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    if (!value.isObject()) return value.dup();
    const symbol_to_primitive = core.atom.predefinedId("Symbol.toPrimitive", .symbol) orelse return toOrdinaryPrimitive(ctx, output, global, value);
    const method = try getValueProperty(ctx, output, global, value, symbol_to_primitive, null, null);
    defer method.free(ctx.runtime);
    if (!method.isUndefined() and !method.isNull()) {
        if (!isCallableValue(method)) return error.TypeError;
        const hint = try value_ops.createStringValue(ctx.runtime, "default");
        defer hint.free(ctx.runtime);
        const primitive = try callValueOrBytecode(ctx, output, global, value, method, &.{hint}, null, null);
        if (primitive.isObject()) {
            primitive.free(ctx.runtime);
            return error.TypeError;
        }
        return primitive;
    }

    return toOrdinaryPrimitive(ctx, output, global, value);
}

pub fn toPrimitiveForNumber(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    if (!value.isObject()) return value.dup();
    const symbol_to_primitive = core.atom.predefinedId("Symbol.toPrimitive", .symbol) orelse return toOrdinaryPrimitiveNumber(ctx, output, global, value);
    const method = try getValueProperty(ctx, output, global, value, symbol_to_primitive, null, null);
    defer method.free(ctx.runtime);
    if (!method.isUndefined() and !method.isNull()) {
        if (!isCallableValue(method)) return error.TypeError;
        const hint = try value_ops.createStringValue(ctx.runtime, "number");
        defer hint.free(ctx.runtime);
        const primitive = try callValueOrBytecode(ctx, output, global, value, method, &.{hint}, null, null);
        if (primitive.isObject()) {
            primitive.free(ctx.runtime);
            return error.TypeError;
        }
        return primitive;
    }

    return toOrdinaryPrimitiveNumber(ctx, output, global, value);
}

pub fn toOrdinaryPrimitive(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, "valueOf", null, null)) |primitive| return primitive;
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, "toString", null, null)) |primitive| return primitive;
    return error.TypeError;
}

pub fn toOrdinaryPrimitiveNumber(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, "valueOf", null, null)) |primitive| return primitive;
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, "toString", null, null)) |primitive| return primitive;
    return error.TypeError;
}

pub fn qjsNumberFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else return core.JSValue.int32(0);
    if (input.isBigInt()) return value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, input));
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, primitive));
    return value_ops.toNumberValue(ctx.runtime, primitive);
}

pub fn qjsBigIntFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.int32(0);
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    defer primitive.free(ctx.runtime);
    if (primitive.asInt32()) |int_value| return value_ops.createBigIntI128(ctx.runtime, int_value);
    if (primitive.asFloat64()) |float_value| {
        return value_ops.integerNumberToBigIntValue(ctx.runtime, float_value);
    }
    var bigint = try value_ops.toBigIntValue(ctx.runtime, primitive);
    defer bigint.deinit();
    return value_ops.createBigIntValue(ctx.runtime, bigint);
}

pub fn qjsBigIntAsN(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    unsigned: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = caller_function;
    _ = caller_frame;
    const bits_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const bits_primitive = try toPrimitiveForNumber(ctx, output, global, bits_input);
    defer bits_primitive.free(ctx.runtime);
    if (bits_primitive.isBigInt() or bits_primitive.isSymbol()) return error.TypeError;
    const bits_number_value = try value_ops.toNumberValue(ctx.runtime, bits_primitive);
    defer bits_number_value.free(ctx.runtime);
    const bits_number = value_ops.numberValue(bits_number_value) orelse 0;
    const bits: usize = if (std.math.isNan(bits_number))
        0
    else blk: {
        if (!std.math.isFinite(bits_number)) return error.RangeError;
        const truncated = @trunc(bits_number);
        if (truncated < 0) return error.RangeError;
        if (truncated > 9007199254740991.0) return error.RangeError;
        break :blk @intFromFloat(truncated);
    };

    const bigint_input = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const bigint_primitive = try toPrimitiveForNumber(ctx, output, global, bigint_input);
    defer bigint_primitive.free(ctx.runtime);
    const bigint_value = try toBigIntFromPrimitive(ctx.runtime, bigint_primitive);
    defer bigint_value.free(ctx.runtime);
    return value_ops.asN(ctx.runtime, core.JSValue.float64(@floatFromInt(bits)), bigint_value, unsigned);
}

pub fn toBigIntFromPrimitive(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isBigInt()) return value.dup();
    if (value.asBool()) |bool_value| return value_ops.createBigIntI128(rt, if (bool_value) 1 else 0);
    if (value.isString()) {
        var bigint = try value_ops.toBigIntValue(rt, value);
        defer bigint.deinit();
        return value_ops.createBigIntValue(rt, bigint);
    }
    return error.TypeError;
}

pub fn qjsGlobalIsNaNOrFinite(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    is_nan: bool,
) !core.JSValue {
    if (objectFromValue(this_value)) |receiver| {
        if (try constructorNameEqlLocal(ctx.runtime, receiver, "Number")) {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const number = value_ops.numberValue(value);
            if (is_nan) return core.JSValue.boolean(value.isNumber() and std.math.isNan(number orelse std.math.nan(f64)));
            return core.JSValue.boolean(value.isNumber() and std.math.isFinite(number orelse std.math.nan(f64)));
        }
    }
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    defer primitive.free(ctx.runtime);
    if (primitive.isSymbol() or primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    return core.JSValue.boolean(if (is_nan) std.math.isNan(number) else std.math.isFinite(number));
}

pub fn valueTruthy(value: core.JSValue) bool {
    return value_ops.isTruthy(value);
}

/// Shared helper for `get_loc` / `get_loc8` / `get_loc0..3`. `consume`
/// is the operand byte width (0 for short, 1 for u8, 2 for u16); the
/// caller has already decoded the index, so we only need to advance pc.
pub fn execGetLoc(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = ctx;
    _ = opc;
    if (idx >= frame.locals.len) return error.InvalidBytecode;
    try pushSlotValue(stack, frame.locals[idx]);
}

pub fn execPutLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
    sync_global_lexical_locals: bool,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.locals.len) return error.InvalidBytecode;
    const value = try stack.pop();
    try setSlotValue(ctx, &frame.locals[idx], value);
    if (idx < frame.locals_uninit.len and idx < function.var_is_lexical.len and function.var_is_lexical[idx]) {
        frame.clearLocalUninitialized(idx);
    }
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
}

pub fn execSetLoc(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
    sync_global_lexical_locals: bool,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.locals.len) return error.InvalidBytecode;
    const value = stack.peek() orelse return error.StackUnderflow;
    defer value.free(ctx.runtime);
    try setSlotValue(ctx, &frame.locals[idx], value.dup());
    if (idx < frame.locals_uninit.len and idx < function.var_is_lexical.len and function.var_is_lexical[idx]) {
        frame.clearLocalUninitialized(idx);
    }
    try syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
}

pub fn syncTopLevelGlobalLexicalLocal(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: usize,
    enabled: bool,
) !void {
    if (!enabled) return;
    if (!try ensureGlobalLexicalSyncSlots(ctx, function, global, frame)) return;
    if (idx >= frame.global_lexical_sync_slots.len or !frame.global_lexical_sync_slots[idx]) return;
    const atom_id = function.var_names[idx];
    if (idx < frame.global_lexical_sync_indices.len) {
        const property_index = frame.global_lexical_sync_indices[idx];
        if (property_index != frame_mod.no_global_lexical_sync_index) {
            const env = frame.global_lexical_sync_env orelse existingGlobalLexicalEnv(ctx) orelse return;
            if (try env.setOwnDataPropertyAtForLexicalSync(ctx.runtime, property_index, atom_id, slotValueBorrow(frame.locals[idx]))) return;
        }
    }
    const value = slotValueDup(frame.locals[idx]);
    defer value.free(ctx.runtime);
    _ = try setGlobalLexicalValue(ctx, atom_id, value);
}

pub fn ensureGlobalLexicalSyncSlots(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
) !bool {
    _ = global;
    if (frame.global_lexical_sync_checked) return frame.global_lexical_sync_slots.len != 0;
    const env = existingGlobalLexicalEnv(ctx) orelse return false;
    frame.global_lexical_sync_env = env;
    const count = @min(function.var_names.len, function.var_is_lexical.len);
    if (count == 0) {
        frame.global_lexical_sync_checked = true;
        return false;
    }
    const slots = try ctx.runtime.memory.alloc(bool, count);
    errdefer ctx.runtime.memory.free(bool, slots);
    @memset(slots, false);
    const indices = try ctx.runtime.memory.alloc(usize, count);
    errdefer ctx.runtime.memory.free(usize, indices);
    @memset(indices, frame_mod.no_global_lexical_sync_index);
    var has_sync_slot = false;
    for (function.var_names[0..count], 0..) |atom_id, idx| {
        if (!function.var_is_lexical[idx]) continue;
        if (!env.hasOwnProperty(atom_id)) continue;
        if (env.getOwnDataPropertyLookup(atom_id)) |lookup| {
            indices[idx] = lookup.index;
            lookup.value.free(ctx.runtime);
        }
        var duplicate_prior = false;
        var prior_idx: usize = 0;
        while (prior_idx < idx) : (prior_idx += 1) {
            if (atomIdOrNameEql(ctx.runtime, function.var_names[prior_idx], atom_id)) {
                duplicate_prior = true;
                break;
            }
        }
        if (duplicate_prior) continue;
        slots[idx] = true;
        has_sync_slot = true;
    }
    frame.global_lexical_sync_checked = true;
    if (!has_sync_slot) {
        ctx.runtime.memory.free(bool, slots);
        ctx.runtime.memory.free(usize, indices);
        return false;
    }
    frame.global_lexical_sync_slots = slots;
    frame.global_lexical_sync_indices = indices;
    return true;
}

pub fn execGetArg(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = ctx;
    _ = opc;
    if (idx >= frame.args.len) {
        try stack.pushOwned(core.JSValue.undefinedValue());
        return;
    }
    try pushSlotValue(stack, frame.args[idx]);
}

pub fn execPutArg(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.args.len) return error.InvalidBytecode;
    const value = try stack.pop();
    try setSlotValue(ctx, &frame.args[idx], value);
}

pub fn execSetArg(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.args.len) return error.InvalidBytecode;
    const value = stack.peek() orelse return error.StackUnderflow;
    defer value.free(ctx.runtime);
    try setSlotValue(ctx, &frame.args[idx], value.dup());
}

pub fn execGetVarRef(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    try pushSlotValue(stack, frame.var_refs[idx]);
}

pub fn execGetVarRefMaybeTdz(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    catch_target: *?usize,
    global: *core.Object,
) !bool {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    const slot = frame.var_refs[idx];
    if (varRefCellFromValue(slot)) |cell| {
        if (cell.varRefIsDeletedSlot().*) {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) {
                return true;
            }
            return error.ReferenceError;
        }
        const value = slotValueBorrow(slot);
        if (value.isUninitialized()) {
            const err = throwTdzReference(ctx);
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
                return true;
            }
            return err;
        }
        try stack.push(value);
        return false;
    }
    if (slot.isUninitialized()) {
        const err = throwTdzReference(ctx);
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
            return true;
        }
        return err;
    }
    try stack.push(slot);
    return false;
}

pub fn execPutVarRef(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
    eval_global_var_bindings: bool,
    is_eval_code: bool,
) !void {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    const value = try stack.pop();
    const slot = frame.var_refs[idx];
    if (varRefCellFromValue(slot)) |cell| {
        if (opc == op.put_var_ref_check_init) {
            const current = cell.varRefValueSlot().* orelse core.JSValue.undefinedValue();
            if (!current.isUninitialized()) {
                value.free(ctx.runtime);
                return error.ReferenceError;
            }
        }
        if (opc == op.put_var_ref_check) {
            const current = cell.varRefValueSlot().* orelse core.JSValue.undefinedValue();
            if (current.isUninitialized()) {
                value.free(ctx.runtime);
                return throwTdzReference(ctx);
            }
        }
        if (cell.varRefIsFunctionNameSlot().*) {
            value.free(ctx.runtime);
            if (function.flags.is_strict) return error.TypeError;
            return;
        }
        if (cell.varRefIsConstSlot().* and !constVarRefWriteAllowed(cell, opc)) {
            value.free(ctx.runtime);
            _ = throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
            return error.TypeError;
        }
        try publishTopLevelFunctionVarRef(ctx.runtime, function, global, frame, idx, value, eval_global_var_bindings, is_eval_code);
        var assigned = value;
        if (varRefCellFromValue(value) != null) {
            assigned = slotValueDup(value);
            value.free(ctx.runtime);
        }
        cell.varRefIsDeletedSlot().* = false;
        errdefer assigned.free(ctx.runtime);
        try cell.setVarRefValue(ctx.runtime, assigned);
        return;
    }
    if (opc == op.put_var_ref_check_init and !slot.isUninitialized()) {
        value.free(ctx.runtime);
        return error.ReferenceError;
    }
    if (opc == op.put_var_ref_check and slot.isUninitialized()) {
        value.free(ctx.runtime);
        return throwTdzReference(ctx);
    }
    if (opc == op.put_var_ref_check and idx < function.var_ref_names.len) {
        const atom_id = function.var_ref_names[idx];
        if (globalLexicalHas(ctx, atom_id)) {
            _ = setGlobalLexicalValue(ctx, atom_id, value) catch |err| {
                value.free(ctx.runtime);
                return err;
            };
            return;
        }
    }
    if (opc == op.put_var_ref_check and idx < function.var_ref_is_const.len and function.var_ref_is_const[idx]) {
        value.free(ctx.runtime);
        _ = throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
        return error.TypeError;
    }
    try publishTopLevelFunctionVarRef(ctx.runtime, function, global, frame, idx, value, eval_global_var_bindings, is_eval_code);
    try setSlotValue(ctx, &frame.var_refs[idx], value);
}

pub fn isVarRefInitOpcode(opc: u8) bool {
    return opc == op.put_var_ref or
        opc == op.put_var_ref_check_init or
        opc == op.put_var_ref0 or
        opc == op.put_var_ref1 or
        opc == op.put_var_ref2 or
        opc == op.put_var_ref3;
}

pub fn constVarRefWriteAllowed(cell: *core.Object, opc: u8) bool {
    _ = cell;
    return isVarRefInitOpcode(opc);
}

pub fn publishTopLevelFunctionVarRef(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    value: core.JSValue,
    eval_global_var_bindings: bool,
    is_eval_code: bool,
) !void {
    if (idx >= function.var_ref_names.len) return;
    if (!value.isObject()) return;
    if (function.flags.is_module) return;
    if (is_eval_code and !eval_global_var_bindings) return;
    if (!sameObjectIdentity(frame.this_value, global.value())) return;
    const object = property_ops.expectObject(value) catch return;
    if (!isFunctionLikeClass(object.class_id)) return;
    try defineGlobalFunctionBindingValue(rt, global, function.var_ref_names[idx], value, is_eval_code);
}

pub fn defineGlobalFunctionBindingValue(
    rt: *core.JSRuntime,
    global: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    configurable: bool,
) !void {
    const desc = if (global.getOwnProperty(atom_id)) |current| blk: {
        defer current.destroy(rt);
        if (current.configurable == true) {
            break :blk core.Descriptor.data(value, true, true, configurable);
        }
        break :blk core.Descriptor{
            .kind = .data,
            .value = value,
            .value_present = true,
        };
    } else core.Descriptor.data(value, true, true, configurable);

    global.defineOwnProperty(rt, atom_id, desc) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        else => return err,
    };
}

pub fn execSetVarRef(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    _ = opc;
    const value = stack.peek() orelse return error.StackUnderflow;
    defer value.free(ctx.runtime);
    try setSlotValue(ctx, &frame.var_refs[idx], value.dup());
}

pub fn slotValueDup(slot: core.JSValue) core.JSValue {
    return slotValueBorrow(slot).dup();
}

pub fn slotValueBorrow(slot: core.JSValue) core.JSValue {
    var current = slot;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const cell = varRefCellFromValue(current) orelse return current;
        current = cell.varRefValueSlot().* orelse return core.JSValue.undefinedValue();
    }
    return current;
}

pub fn varRefSlotIsUninitialized(slot: core.JSValue) bool {
    return slotValueBorrow(slot).tag == core.Tag.uninitialized;
}

pub fn varRefSlotIsDeleted(slot: core.JSValue) bool {
    const cell = varRefCellFromValue(slot) orelse return false;
    return cell.varRefIsDeletedSlot().*;
}

pub fn evalLocalSlotIsEvalVarCell(slot: core.JSValue) bool {
    const cell = varRefCellFromValue(slot) orelse return false;
    return cell.varRefIsDeletableSlot().*;
}

pub fn setSlotValue(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) !void {
    if (!slot.requiresRefCount() and !value.requiresRefCount()) {
        slot.* = value;
        return;
    }
    var assigned = value;
    if (varRefCellFromValue(value) != null) {
        assigned = slotValueDup(value);
        value.free(ctx.runtime);
    }
    if (varRefCellFromValue(slot.*)) |cell| {
        cell.varRefIsDeletedSlot().* = false;
        try cell.setVarRefValue(ctx.runtime, assigned);
        return;
    }
    const old_value = slot.*;
    slot.* = assigned;
    old_value.free(ctx.runtime);
}

pub fn derivedConstructorThisLocalSlot(frame: *frame_mod.Frame) ?*core.JSValue {
    if (!frame.function.flags.is_derived_class_constructor) return null;
    for (frame.function.var_names, 0..) |name, idx| {
        if (name == 8 and idx < frame.locals.len) return &frame.locals[idx];
    }
    return null;
}

pub fn closeLocalVarRef(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: u16) !void {
    if (idx >= frame.locals.len) return error.InvalidBytecode;
    const cell = varRefCellFromValue(frame.locals[idx]) orelse return;
    const value = if (cell.varRefValueSlot().*) |stored| stored.dup() else core.JSValue.undefinedValue();
    const old_value = frame.locals[idx];
    frame.locals[idx] = value;
    old_value.free(ctx.runtime);
}

pub fn functionBytecodeHasDirectEval(fb: *const bytecode.FunctionBytecode, rt: *core.JSRuntime) bool {
    _ = rt;
    var pc: usize = 0;
    while (pc < fb.byte_code.len) {
        const opc = fb.byte_code[pc];
        if (opc == op.eval or opc == op.apply_eval) return true;
        const size = bytecode.opcode.sizeOf(opc);
        pc += if (size == 0) 1 else size;
    }
    return false;
}

pub fn functionBytecodeUsesImportMeta(fb: *const bytecode.FunctionBytecode) bool {
    var pc: usize = 0;
    while (pc < fb.byte_code.len) {
        const opc = fb.byte_code[pc];
        if (opc == op.special_object and pc + 1 < fb.byte_code.len and fb.byte_code[pc + 1] == 4) return true;
        const size = bytecode.opcode.sizeOf(opc);
        pc += if (size == 0) 1 else size;
    }
    return false;
}

pub fn evalBytecodeHasVarDeclarations(rt: *core.JSRuntime, function: *const bytecode.Bytecode) bool {
    if (!value_ops.atomNameEql(rt, function.name, "<eval>")) return false;
    for (function.var_names) |atom_id| {
        if (!value_ops.atomNameEql(rt, atom_id, "<ret>")) return true;
    }
    return false;
}

pub fn shouldSkipDirectEvalLocalCapture(
    fb: *const bytecode.FunctionBytecode,
    slot: core.JSValue,
    skip_values: []const core.JSValue,
) bool {
    const value = if (varRefCellFromValue(slot)) |cell|
        cell.varRefValueSlot().* orelse core.JSValue.undefinedValue()
    else
        slot;
    if (value.isUninitialized()) return true;
    if (!fb.super_allowed) return false;
    if (!value.isObject()) return false;
    for (skip_values) |skip_value| {
        if (skip_value.same(value)) return true;
    }
    return false;
}

pub fn functionBytecodeUsesAtom(fb: *const bytecode.FunctionBytecode, atom_id: core.Atom) bool {
    for (fb.atom_operands) |operand| {
        if (operand == atom_id) return true;
    }
    for (fb.var_ref_names) |name| {
        if (name == atom_id) return true;
    }
    return false;
}

pub fn functionBytecodeHasClosureVarName(fb: *const bytecode.FunctionBytecode, atom_id: core.Atom) bool {
    for (fb.closure_var) |cv| {
        if (cv.var_name == atom_id) return true;
    }
    return false;
}

pub fn shouldSkipDirectEvalScopeCaptureName(
    rt: *core.JSRuntime,
    captures_direct_eval_scope: bool,
    fb: *const bytecode.FunctionBytecode,
    atom_id: core.Atom,
) bool {
    if (!captures_direct_eval_scope) return false;
    if (fb.func_name == core.atom.ids.empty_string) return false;
    return atomIdOrNameEql(rt, fb.func_name, atom_id);
}

pub fn appendFunctionEvalLocal(ctx: *core.JSContext, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    for (object.functionEvalLocalNamesSlot().*, 0..) |name, idx| {
        if (!atomIdOrNameEql(ctx.runtime, name, atom_id) or idx >= object.functionEvalLocalRefsSlot().*.len) continue;
        var next = value.dup();
        errdefer next.free(ctx.runtime);
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &next },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = ctx.runtime.active_value_roots,
            .values = &root_values,
        };
        ctx.runtime.active_value_roots = &root_frame;
        defer ctx.runtime.active_value_roots = root_frame.previous;
        const ref_slot = &object.functionEvalLocalRefsSlot().*[idx];
        try ctx.runtime.writeBarrierValueAt(&object.header, next, ref_slot);
        const old_value = ref_slot.*;
        ref_slot.* = next;
        old_value.free(ctx.runtime);
        return;
    }

    const old_len = object.functionEvalLocalNamesSlot().*.len;
    const names = try ctx.runtime.memory.alloc(core.Atom, old_len + 1);
    errdefer ctx.runtime.memory.free(core.Atom, names);
    const refs = try ctx.runtime.memory.alloc(core.JSValue, old_len + 1);
    errdefer ctx.runtime.memory.free(core.JSValue, refs);
    var rooted_refs: []core.JSValue = refs[0..0];
    var refs_root = ValueSliceRoot{};
    refs_root.init(ctx.runtime, &rooted_refs);
    defer refs_root.deinit();

    for (object.functionEvalLocalNamesSlot().*, 0..) |name, idx| names[idx] = name;
    for (object.functionEvalLocalRefsSlot().*, 0..) |stored, idx| refs[idx] = stored;
    rooted_refs = refs[0..old_len];
    names[old_len] = ctx.runtime.atoms.dup(atom_id);
    var name_owned = true;
    errdefer if (name_owned) ctx.runtime.atoms.free(names[old_len]);
    refs[old_len] = value.dup();
    rooted_refs = refs[0 .. old_len + 1];
    var value_owned = true;
    errdefer if (value_owned) {
        refs[old_len].free(ctx.runtime);
        refs[old_len] = core.JSValue.undefinedValue();
        rooted_refs = refs[0..old_len];
    };

    const old_names = object.functionEvalLocalNamesSlot().*;
    const old_refs = object.functionEvalLocalRefsSlot().*;
    try object.writeValueSliceBarrier(ctx.runtime, refs);
    name_owned = false;
    value_owned = false;
    object.functionEvalLocalNamesSlot().* = names;
    object.functionEvalLocalRefsSlot().* = refs;
    if (old_names.len != 0) ctx.runtime.memory.free(core.Atom, old_names);
    if (old_refs.len != 0) ctx.runtime.memory.free(core.JSValue, old_refs);
}

test "appendFunctionEvalLocal roots new refs while write barrier records slice" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const owner_value = try builtins.function.nativeFunction(rt, "owner", 0);
    defer owner_value.free(rt);
    const owner = objectFromValue(owner_value) orelse return error.TypeError;
    owner.header.setGeneration(.old);
    const child = try core.Object.create(rt, core.class.ids.object, null);
    defer child.value().free(rt);
    child.header.setGeneration(.young);
    const child_value = child.value();

    const name = try rt.internAtom("rootedEvalLocal");
    defer rt.atoms.free(name);

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var probe = ActiveRootValueProbe{
        .rt = rt,
        .target = child_value,
    };
    rt.memory.trigger_gc_fn = ActiveRootValueProbe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
        rt.gc.clearRememberedSet();
    }

    try appendFunctionEvalLocal(ctx, owner, name, child_value);

    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.match_count >= 1);
    try std.testing.expectEqual(@as(usize, 1), owner.functionEvalLocalRefsSlot().*.len);
    try std.testing.expect(owner.functionEvalLocalRefsSlot().*[0].same(child_value));
}

pub const ExecCallResult = enum { done, continue_loop };

pub fn execCall(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    argc: u16,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !ExecCallResult {
    var inline_args: [4]core.JSValue = undefined;
    const args: []core.JSValue = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.JSValue, args);

    var filled_start: usize = args.len;
    errdefer {
        var i = filled_start;
        while (i < args.len) : (i += 1) args[i].free(ctx.runtime);
    }
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args[remaining] = try stack.pop();
        filled_start = remaining;
    }
    filled_start = args.len;
    defer {
        for (args) |arg| arg.free(ctx.runtime);
    }

    var func = try stack.pop();
    defer func.free(ctx.runtime);
    var rooted_args = args;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &func },
    };
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &rooted_args },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
        .slices = &root_slices,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if (try fastHostOutputCall(ctx.runtime, output, func, args)) {
        try stack.pushOwned(core.JSValue.undefinedValue());
        return .done;
    }
    const is_super_constructor = isCurrentSuperConstructor(ctx, frame, func);
    const arrow_super_this = if (is_super_constructor and !frame.function.flags.is_derived_class_constructor)
        currentArrowLexicalSuperThis(ctx.runtime, frame)
    else
        null;
    defer if (arrow_super_this) |value| value.free(ctx.runtime);
    const arrow_constructor_this = if (is_super_constructor and !frame.function.flags.is_derived_class_constructor)
        currentArrowConstructorThis(ctx.runtime, frame)
    else
        null;
    defer if (arrow_constructor_this) |value| value.free(ctx.runtime);
    const is_arrow_super_constructor = is_super_constructor and arrow_super_this != null;
    const super_this = if (is_super_constructor and frame.function.flags.is_derived_class_constructor)
        frame.constructor_this_value
    else if (arrow_constructor_this) |value|
        value
    else if (arrow_super_this) |value|
        value
    else
        core.JSValue.undefinedValue();
    const result = callValueOrBytecodeClassMode(ctx, output, global, super_this, func, rooted_args, function, frame, is_super_constructor) catch |err| {
        try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
        if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
            return .continue_loop;
        }
        return err;
    };
    if (is_super_constructor and frame.function.flags.is_derived_class_constructor) {
        defer result.free(ctx.runtime);
        if (varRefSlotIsUninitialized(frame.this_value)) {
            const next_this = if (result.isObject()) result else frame.constructor_this_value;
            try setSlotValue(ctx, &frame.this_value, next_this.dup());
            initializeCurrentConstructorClassInstanceElements(ctx, output, global, function, frame) catch |err| {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
                    return .continue_loop;
                }
                return err;
            };
        } else {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) {
                return .continue_loop;
            }
            return error.ReferenceError;
        }
        try pushSlotValue(stack, frame.this_value);
        return .done;
    }
    if (is_arrow_super_constructor) {
        defer result.free(ctx.runtime);
        if (arrow_super_this) |this_value_for_arrow| {
            if (!this_value_for_arrow.isUninitialized()) {
                if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) {
                    return .continue_loop;
                }
                return error.ReferenceError;
            }
        }
        const next_this = if (result.isObject())
            result
        else if (arrow_constructor_this) |value|
            value
        else
            result;
        try setCurrentArrowLexicalThis(ctx, frame, next_this.dup());
        try stack.push(next_this);
        return .done;
    }
    stack.pushOwned(result) catch |err| {
        result.free(ctx.runtime);
        return err;
    };
    return .done;
}

pub fn fastHostOutputCall(rt: *core.JSRuntime, output: ?*std.Io.Writer, func: core.JSValue, args: []const core.JSValue) !bool {
    const object = objectFromValue(func) orelse return false;
    if (object.hostFunctionKind() != core.host_function.ids.output) return false;
    try printHostOutputArgs(rt, output, args);
    return true;
}

pub fn printHostOutputArgs(rt: *core.JSRuntime, output: ?*std.Io.Writer, args: []const core.JSValue) !void {
    if (output) |writer| {
        for (args, 0..) |arg, idx| {
            if (idx != 0) try writer.writeByte(' ');
            try call_mod.printValue(rt, writer, arg);
        }
        try writer.writeByte('\n');
    }
}

pub const ExecEvalResult = enum { done, continue_loop };

pub fn execDirectEval(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    argc: u16,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_in_class_field_initializer: bool,
    eval_in_parameter_initializer: bool,
) !ExecEvalResult {
    var args: []core.JSValue = &.{};
    if (argc != 0) args = try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (args.len != 0) ctx.runtime.memory.free(core.JSValue, args);

    var filled_start: usize = args.len;
    errdefer {
        var i = filled_start;
        while (i < args.len) : (i += 1) args[i].free(ctx.runtime);
    }
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args[remaining] = try stack.pop();
        filled_start = remaining;
    }
    filled_start = args.len;
    defer {
        for (args) |arg| arg.free(ctx.runtime);
    }

    var func = try stack.pop();
    defer func.free(ctx.runtime);
    var rooted_args = args;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &func },
    };
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &rooted_args },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
        .slices = &root_slices,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const result = if (isContextIntrinsicEval(ctx, func))
        directEval(ctx, output, global, rooted_args, function, frame, eval_in_class_field_initializer, eval_in_parameter_initializer) catch |err| {
            const eval_err = normalizeEvalRuntimeError(err);
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, eval_err)) {
                return .continue_loop;
            }
            return eval_err;
        }
    else
        callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), func, rooted_args, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
                return .continue_loop;
            }
            return err;
        };
    defer result.free(ctx.runtime);
    try stack.push(result);
    return .done;
}

pub fn isContextIntrinsicEval(ctx: *core.JSContext, func: core.JSValue) bool {
    return func.isObject() and func.same(ctx.eval_function);
}

pub fn execApplyEval(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_in_class_field_initializer: bool,
    eval_in_parameter_initializer: bool,
) !ExecEvalResult {
    var arg_array = try stack.pop();
    defer arg_array.free(ctx.runtime);
    var func = try stack.pop();
    defer func.free(ctx.runtime);
    var value_roots = [_]core.runtime.ValueRootValue{
        .{ .value = &arg_array },
        .{ .value = &func },
    };
    const value_root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &value_roots,
    };
    ctx.runtime.active_value_roots = &value_root_frame;
    defer ctx.runtime.active_value_roots = value_root_frame.previous;

    var args = try argsFromArray(ctx.runtime, arg_array);
    defer freeArgs(ctx.runtime, args);
    var args_root = ValueSliceRoot{};
    args_root.init(ctx.runtime, &args);
    defer args_root.deinit();
    const result = if (isContextIntrinsicEval(ctx, func))
        directEval(ctx, output, global, args, function, frame, eval_in_class_field_initializer, eval_in_parameter_initializer) catch |err| {
            const eval_err = normalizeEvalRuntimeError(err);
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, eval_err)) {
                return .continue_loop;
            }
            return eval_err;
        }
    else
        callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), func, args, function, frame) catch |err| {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) {
                return .continue_loop;
            }
            return err;
        };
    defer result.free(ctx.runtime);
    try stack.push(result);
    return .done;
}

pub fn qjsCollectionNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return collection_vm.qjsCollectionNativeRecord(ctx, output, global, this_value, function_object, id, args, caller_function, caller_frame);
}

pub fn qjsMapGroupByRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    prototype: ?*core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return collection_vm.qjsMapGroupByRecord(ctx, output, global, args, prototype, caller_function, caller_frame);
}

pub fn qjsBufferNativeRecord(
    ctx: *core.JSContext,
    receiver: core.JSValue,
    id: u32,
    args: []const core.JSValue,
) !?core.JSValue {
    if (id == @intFromEnum(builtins.buffer.StaticMethod.is_view)) return qjsArrayBufferIsView(args);
    if (builtins.buffer.arrayBufferAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsArrayBufferAccessor(ctx, receiver, accessor_name));
    }
    if (builtins.buffer.sharedArrayBufferAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsSharedArrayBufferAccessor(ctx, receiver, accessor_name));
    }
    if (builtins.buffer.dataViewAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsDataViewAccessor(ctx, receiver, accessor_name));
    }
    if (builtins.buffer.typedArrayAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsTypedArrayAccessor(ctx, receiver, accessor_name));
    }
    if (try qjsArrayBufferPrototypeNativeRecord(ctx, receiver, id, args)) |value| return value;
    if (builtins.buffer.dataViewGetKindFromRecordId(id)) |method_id| {
        const global = ctx.global orelse {
            const value = try (builtins.buffer.dataViewGet(ctx.runtime, receiver, method_id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                error.RangeError => error.RangeError,
                else => err,
            });
            return @as(?core.JSValue, value);
        };
        const value = try (qjsDataViewGet(ctx, null, global, receiver, method_id, args) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            error.RangeError => error.RangeError,
            else => err,
        });
        return @as(?core.JSValue, value);
    }
    if (builtins.buffer.dataViewSetKindFromRecordId(id)) |method_id| {
        const global = ctx.global orelse {
            const value = try (builtins.buffer.dataViewSet(ctx.runtime, receiver, method_id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                error.RangeError => error.RangeError,
                else => err,
            });
            return @as(?core.JSValue, value);
        };
        const value = try (qjsDataViewSet(ctx, null, global, receiver, method_id, args) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            error.RangeError => error.RangeError,
            else => err,
        });
        return @as(?core.JSValue, value);
    }
    return null;
}

pub fn handleCatchableRuntimeError(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    err: anytype,
) !bool {
    core.profile.recordSlowPath();
    const is_pending_exception = exception_ops.pendingExceptionMatchesError(ctx, err);
    const error_info = if (is_pending_exception) null else exception_ops.runtimeErrorInfo(err) orelse return false;
    const target = catch_target.* orelse return false;
    closeFrameDestructuringIteratorsForAbruptCompletion(ctx, null, global, stack, frame);
    try stack.reserveAdditional(1);
    var catch_value: core.JSValue = if (is_pending_exception)
        ctx.takeException()
    else
        try createNamedError(ctx.runtime, global, error_info.?.name, error_info.?.message);
    var catch_value_owned = true;
    errdefer if (catch_value_owned) {
        if (is_pending_exception) {
            _ = ctx.throwValue(catch_value);
        } else {
            catch_value.free(ctx.runtime);
        }
    };
    if (!is_pending_exception and ctx.hasException()) ctx.clearException();
    const restored = (try popCatchMarker(ctx.runtime, stack)) orelse null;
    stack.pushOwnedAssumeCapacity(catch_value);
    catch_value_owned = false;
    frame.dropPreparedCallsForCatchDepth(ctx.runtime, stack.values.len);
    frame.pc = target;
    catch_target.* = restored;
    return true;
}

pub fn callValueOrBytecode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return callValueOrBytecodeClassMode(ctx, output, global, this_value, func, args, caller_function, caller_frame, false);
}

pub fn callNativeBuiltinRecordForVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    this_value: core.JSValue,
    function_object: *core.Object,
    native_ref: core.function.NativeBuiltinRef,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    switch (native_ref.domain) {
        .math => {
            if (native_ref.id == builtins.math.sum_precise_method_id) return try qjsMathSumPrecise(ctx, output, global, args, caller_function, caller_frame);
            return try qjsMathCall(ctx, output, global, native_ref.id, args);
        },
        .number => return try call_mod.callNativeFunctionRecord(ctx, output, global, &.{}, this_value, function_object, args, caller_function, caller_frame),
        .collection => return try collection_vm.qjsCollectionNativeRecord(ctx, output, global, this_value, function_object, native_ref.id, args, caller_function, caller_frame),
        .regexp => return try qjsRegExpNativeCallById(ctx, output, global, func, this_value, native_ref.id, args, caller_function, caller_frame),
        .uri => return try qjsUriCallForNativeRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame),
        .json => return try qjsJsonCallForNativeRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame),
        .atomics => return try qjsAtomicsCallForNativeRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame),
        .reflect => return try qjsReflectCallForNativeRecord(ctx, output, global, native_ref.id, args, caller_function, caller_frame),
        .object => return try qjsObjectCallForNativeRecord(ctx, output, global, this_value, native_ref.id, args, caller_function, caller_frame),
        .primitive => return try qjsPrimitivePrototypeMethod(ctx, output, global, function_object, this_value, native_ref.id, args, caller_function, caller_frame),
        .function => switch (native_ref.id) {
            @intFromEnum(builtins.function.PrototypeMethod.to_string) => return try qjsFunctionToStringCall(ctx, this_value),
            else => {},
        },
        .error_object => switch (native_ref.id) {
            @intFromEnum(builtins.error_.PrototypeMethod.to_string) => return try qjsErrorToStringCall(ctx, output, global, this_value, caller_function, caller_frame),
            @intFromEnum(builtins.error_.PrototypeMethod.stack_getter) => return try qjsErrorStackGetter(ctx, output, global, this_value),
            @intFromEnum(builtins.error_.PrototypeMethod.stack_setter) => return try qjsErrorStackSetter(ctx, output, global, this_value, function_object, args, caller_function, caller_frame),
            else => {},
        },
        .iterator => return try qjsIteratorCallForNativeRecord(ctx, output, global, this_value, native_ref.id, args, caller_function, caller_frame),
        .string => {
            if (native_ref.id == @intFromEnum(builtins.string.ConstructorMethod.call)) {
                return try qjsStringFunctionCall(ctx, output, global, args, caller_function, caller_frame);
            }
            if (native_ref.id == @intFromEnum(builtins.string.PrototypeMethod.substring)) {
                return try qjsStringPrototypeMethod(ctx, output, global, this_value, 1, args, caller_function, caller_frame);
            }
        },
        .date => {
            if (native_ref.id == @intFromEnum(builtins.date.StaticMethod.now)) {
                return try builtins.date.staticCall(ctx.runtime, native_ref.id, args);
            }
            if (native_ref.id == @intFromEnum(builtins.date.PrototypeMethod.to_primitive)) {
                return try qjsDateToPrimitiveNativeRecord(ctx, output, global, this_value, args, caller_function, caller_frame);
            }
        },
        else => {},
    }
    return null;
}

pub fn throwRuntimeErrorForGlobal(ctx: *core.JSContext, global: *core.Object, err: anytype) !void {
    if (exception_ops.pendingExceptionMatchesError(ctx, err)) return;
    const error_info = exception_ops.runtimeErrorInfo(err) orelse return;
    const error_value = try createNamedError(ctx.runtime, global, error_info.name, error_info.message);
    errdefer error_value.free(ctx.runtime);
    try attachStackToErrorValue(ctx, global, error_value);
    if (ctx.hasException()) ctx.clearException();
    _ = ctx.throwValue(error_value);
}

pub fn callValueOrBytecodeClassMode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    input_this_value: core.JSValue,
    input_func: core.JSValue,
    input_args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    allow_class_constructor_call: bool,
) HostError!core.JSValue {
    var this_value = input_this_value;
    var func = input_func;
    var inline_args: [8]core.JSValue = undefined;
    var args_buffer: core.runtime.ValueRootBuffer = .{};
    defer args_buffer.deinit(ctx.runtime);
    var args: []core.JSValue = inline_args[0..0];
    if (input_args.len <= inline_args.len) {
        args = inline_args[0..input_args.len];
        @memcpy(args, input_args);
    } else {
        args_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, input_args);
        args = args_buffer.values;
    }
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &this_value },
        .{ .value = &func },
    };
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &args },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
        .slices = &root_slices,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if (func.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(func) orelse return error.TypeError;
        if (allow_class_constructor_call and !fb.is_class_constructor) {
            if (fb.is_arrow_function or !fb.has_prototype or fb.func_kind == .generator or fb.func_kind == .async_generator) return error.TypeError;
            const result = try callFunctionBytecodeConstruct(ctx, func, func, this_value, args, &.{}, output, global, &.{}, &.{}, classConstructorNewTarget(func, caller_frame), core.JSValue.undefinedValue());
            defer result.free(ctx.runtime);
            return if (result.isObject()) result.dup() else this_value.dup();
        }
        if (fb.is_class_constructor) {
            if (!allow_class_constructor_call) return error.TypeError;
            const initial_this = if (fb.is_derived_class_constructor) core.JSValue.uninitialized() else this_value;
            const constructor_this = if (fb.is_derived_class_constructor) this_value else core.JSValue.undefinedValue();
            if (!fb.is_derived_class_constructor) {
                try initializeClassInstanceElements(ctx, output, global, func, this_value, fb, caller_function, caller_frame);
            }
            return callFunctionBytecodeModeState(ctx, func, func, initial_this, args, &.{}, output, global, &.{}, &.{}, true, null, null, null, classConstructorNewTarget(func, caller_frame), constructor_this);
        }
        if (!allow_class_constructor_call) {
            if (try callSimpleStringBytecode(ctx.runtime, fb, args)) |value| return value;
            if (try callSimpleNumericBytecode(ctx.runtime, fb, args, &.{})) |value| return value;
        }
        return callFunctionBytecode(ctx, func, func, this_value, args, &.{}, output, global, &.{}, &.{});
    }
    if (functionObjectFromValue(func)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (allow_class_constructor_call and !fb.is_class_constructor) {
            if (fb.is_arrow_function or !fb.has_prototype or fb.func_kind == .generator or fb.func_kind == .async_generator) return error.TypeError;
            const function_global = objectRealmGlobal(function_object) orelse global;
            const result = try callFunctionBytecodeConstruct(ctx, function_value, func, this_value, args, function_object.functionCapturesSlot().*, output, function_global, function_object.functionEvalLocalNamesSlot().*, function_object.functionEvalLocalRefsSlot().*, classConstructorNewTarget(func, caller_frame), core.JSValue.undefinedValue());
            defer result.free(ctx.runtime);
            return if (result.isObject()) result.dup() else this_value.dup();
        }
        if (fb.is_class_constructor) {
            if (!allow_class_constructor_call) return throwFunctionRealmTypeError(ctx, global, function_object);
            const initial_this = if (fb.is_derived_class_constructor) core.JSValue.uninitialized() else this_value;
            const constructor_this = if (fb.is_derived_class_constructor) this_value else core.JSValue.undefinedValue();
            const function_global = objectRealmGlobal(function_object) orelse global;
            if (!fb.is_derived_class_constructor) {
                try initializeClassInstanceElements(ctx, output, function_global, func, this_value, fb, caller_function, caller_frame);
            }
            return callFunctionBytecodeModeState(ctx, function_value, func, initial_this, args, function_object.functionCapturesSlot().*, output, function_global, function_object.functionEvalLocalNamesSlot().*, function_object.functionEvalLocalRefsSlot().*, true, null, null, null, classConstructorNewTarget(func, caller_frame), constructor_this);
        }
        if (!allow_class_constructor_call) {
            if (try callSimpleStringBytecode(ctx.runtime, fb, args)) |value| return value;
            if (try callSimpleNumericBytecode(ctx.runtime, fb, args, function_object.functionCapturesSlot().*)) |value| return value;
        }
        const effective_this = function_object.functionLexicalThisSlot().* orelse this_value;
        const effective_new_target = if (fb.is_arrow_function) blk: {
            if (function_object.functionArrowNewTarget()) |new_target| break :blk new_target.dup();
            break :blk core.JSValue.undefinedValue();
        } else core.JSValue.undefinedValue();
        defer effective_new_target.free(ctx.runtime);
        const function_global = objectRealmGlobal(function_object) orelse global;
        return callFunctionBytecodeModeState(ctx, function_value, func, effective_this, args, function_object.functionCapturesSlot().*, output, function_global, function_object.functionEvalLocalNamesSlot().*, function_object.functionEvalLocalRefsSlot().*, true, null, null, null, effective_new_target, core.JSValue.undefinedValue());
    }
    if (objectFromValue(func)) |object| {
        if (object.proxyTarget() != null and proxyTargetIsCallable(func)) {
            return callProxyApply(ctx, output, global, func, object, this_value, args, caller_function, caller_frame);
        }
    }
    if (callableObjectFromValue(func)) |function_object| {
        if (function_object.class_id == core.class.ids.bound_function) {
            return callBoundFunction(ctx, output, global, function_object, args, caller_function, caller_frame);
        }
        if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*)) |native_ref| {
            const function_global = objectRealmGlobal(function_object) orelse global;
            const native_result = callNativeBuiltinRecordForVm(ctx, output, function_global, func, this_value, function_object, native_ref, args, caller_function, caller_frame) catch |err| {
                try throwRuntimeErrorForGlobal(ctx, function_global, err);
                return err;
            };
            if (native_result) |value| {
                return value;
            }
        }
        if (try call_mod.callHostFunctionObjectForVm(ctx, output, global, function_object, this_value, args)) |value| return value;
        if (try qjsPromiseResolvingFunctionCall(ctx, output, global, function_object, args, caller_function, caller_frame)) |value| return value;
        if (try qjsPromiseThenableJobCall(ctx, output, global, function_object, caller_function, caller_frame)) |value| return value;
        if (try qjsPromiseReactionJobCall(ctx, output, global, function_object, caller_function, caller_frame)) |value| return value;
        if (try qjsPromiseCapabilityExecutorCall(ctx, function_object, args)) |value| return value;
        if (try qjsPromiseCombinatorElementCall(ctx, output, global, function_object, args, caller_function, caller_frame)) |value| return value;
        if (try qjsPromiseFinallyCallbackCall(ctx, output, global, function_object, args, caller_function, caller_frame)) |value| return value;
        if (try qjsAsyncFunctionResumeCallbackCall(ctx, output, global, function_object, args, caller_function, caller_frame)) |value| return value;
        if (try qjsAsyncFromSyncIteratorUnwrapCall(ctx, global, function_object, args)) |value| return value;
        if (try qjsAsyncDisposableStackContinuationCall(ctx, output, global, function_object, args, caller_function, caller_frame)) |value| return value;
        if (isThrowTypeErrorIntrinsicObject(function_object)) return qjsThrowTypeErrorIntrinsic(ctx, global, function_object);
        // Borrow the internal dispatch-name bytes instead of allocating a
        // fresh `[]u8` per call. Hot URI 4-byte-UTF-8 sweeps call this path millions of
        // times, and the previous round-trip alloc/free showed up clearly
        // on the profile. Native dispatch names are atom-backed ASCII
        // builtin names in practice; a `null` return here means there is
        // no usable dispatch name.
        const dispatch = call_mod.nativeFunctionDispatchNameRef(ctx.runtime, function_object) orelse {
            return core.JSValue.undefinedValue();
        };
        defer dispatch.name_value.free(ctx.runtime);
        const name = dispatch.name;
        if (name.len == 0) return core.JSValue.undefinedValue();
        if (std.mem.eql(u8, name, "Worker")) return qjsWorkerFunctionCall(ctx, output, global, args);
        if (std.mem.eql(u8, name, "poll")) return qjsWorkerPoll(ctx, output, global);
        if (std.mem.eql(u8, name, "sleep")) return qjsWorkerSleep(args);
        if (std.mem.eql(u8, name, "postMessage")) {
            switch (function_object.functionWorkerPostTarget()) {
                @intFromEnum(WorkerPostTarget.worker) => return qjsWorkerPostMessage(ctx, this_value, args, .worker),
                @intFromEnum(WorkerPostTarget.parent) => return qjsWorkerPostMessage(ctx, this_value, args, .parent),
                0 => {},
                else => return error.TypeError,
            }
        }
        if (allow_class_constructor_call and isBuiltinConstructorName(name)) {
            if (try constructBuiltinSuperConstructor(ctx, output, global, func, name, args, caller_function, caller_frame, null)) |constructed| {
                return constructed;
            }
            return this_value.dup();
        }
        if (allow_class_constructor_call and !isConstructorLike(ctx, func)) return error.TypeError;
        if (std.mem.eql(u8, name, "raw")) {
            return qjsStringRaw(ctx, output, global, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "[Symbol.hasInstance]")) {
            return qjsFunctionHasInstanceCall(ctx, output, global, this_value, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "sumPrecise")) {
            return qjsMathSumPrecise(ctx, output, global, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "register")) {
            return qjsFinalizationRegistryRegister(ctx, this_value, args);
        }
        if (std.mem.eql(u8, name, "unregister")) {
            return qjsFinalizationRegistryUnregister(ctx, this_value, args);
        }
        if (try qjsDisposableStackMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| {
            return value;
        }
        if (try qjsAsyncDisposableStackMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| {
            return value;
        }
        if (try call_mod.callNativeFunctionRecord(ctx, output, global, &.{}, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        if (try collection_vm.qjsCollectionIteratorMethodCall(ctx, global, this_value, function_object, name, args)) |value| {
            return value;
        }
        if (try collection_vm.qjsCollectionForEachCall(ctx, output, global, this_value, function_object, name, args, caller_function, caller_frame)) |value| {
            return value;
        }
        if (try collection_vm.qjsSetMethodCall(ctx, output, global, this_value, function_object, name, args, caller_function, caller_frame)) |value| {
            return value;
        }
        if (qjsPromiseStaticMode(name)) |mode| {
            if (try qjsPromiseStaticBuiltinCallee(ctx.runtime, global, function_object, name)) {
                return qjsPromiseStaticCall(ctx, output, global, this_value, args, mode, caller_function, caller_frame);
            }
        }
        // Hot-path dispatch: a small first-byte switch routes the common
        // global builtins directly to their handlers, bypassing the long
        // `std.mem.eql` chain below. The previous chain walked ~95 checks
        // before reaching `qjsUriCallId` for `decodeURI` / `encodeURI`,
        // which dominated tight-loop URI benchmarks.
        if (name.len != 0) {
            switch (name[0]) {
                'A' => if (std.mem.eql(u8, name, "Array")) {
                    return builtins.array.constructConstructorWithPrototype(ctx.runtime, args, arrayPrototypeFromGlobal(ctx.runtime, global)) catch |err| switch (err) {
                        error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid array length"),
                        else => err,
                    };
                },
                'B' => if (std.mem.eql(u8, name, "BigInt")) {
                    return qjsBigIntFunctionCall(ctx, output, global, args);
                },
                'N' => if (std.mem.eql(u8, name, "Number")) {
                    return qjsNumberFunctionCall(ctx, output, global, args);
                },
                'O' => if (std.mem.eql(u8, name, "Object")) {
                    return construct_mod.constructValue(ctx.runtime, func, args, &.{});
                },
                'S' => if (std.mem.eql(u8, name, "String")) {
                    return qjsStringFunctionCall(ctx, output, global, args, caller_function, caller_frame);
                },
                'd', 'e' => if (builtins.uri.methodId(name)) |mode| {
                    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
                    if (input.isString()) {
                        return builtins.uri.call(ctx.runtime, mode, input) catch |err| switch (err) {
                            error.TypeError, error.URIError => err,
                            else => err,
                        };
                    }
                    const string_value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
                    defer string_value.free(ctx.runtime);
                    return builtins.uri.call(ctx.runtime, mode, string_value) catch |err| switch (err) {
                        error.TypeError, error.URIError => err,
                        else => err,
                    };
                },
                'f' => if (std.mem.eql(u8, name, "fromCharCode")) {
                    // Skip the long `std.mem.eql` chain below for the
                    // canonical `String.fromCharCode` shape; routes
                    // straight to the same handler the slow path uses,
                    // so coercion semantics (e.g. string args, BigInt
                    // rejection) stay identical.
                    return qjsStringFromCharCode(ctx, output, global, args);
                },
                'r' => if (std.mem.eql(u8, name, "raw")) {
                    return qjsStringRaw(ctx, output, global, args, caller_function, caller_frame);
                },
                else => {},
            }
        }
        if (std.mem.eql(u8, name, "get [Symbol.species]")) return this_value.dup();
        if (std.mem.eql(u8, name, "for")) return qjsSymbolFor(ctx, output, global, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "keyFor")) return qjsSymbolKeyFor(ctx.runtime, args);
        if (std.mem.eql(u8, name, "Function")) return constructFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "AsyncFunction")) return constructAsyncFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "GeneratorFunction")) return constructGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "AsyncGeneratorFunction")) return constructAsyncGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "Worker")) return qjsWorkerFunctionCall(ctx, output, global, args);
        if (std.mem.eql(u8, name, "Object")) return construct_mod.constructValue(ctx.runtime, func, args, &.{});
        if (std.mem.eql(u8, name, "Array")) return builtins.array.constructConstructorWithPrototype(ctx.runtime, args, arrayPrototypeFromGlobal(ctx.runtime, global)) catch |err| switch (err) {
            error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid array length"),
            else => err,
        };
        if (std.mem.eql(u8, name, "String")) return qjsStringFunctionCall(ctx, output, global, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "Number")) return qjsNumberFunctionCall(ctx, output, global, args);
        if (std.mem.eql(u8, name, "BigInt")) return qjsBigIntFunctionCall(ctx, output, global, args);
        if (std.mem.eql(u8, name, "parseInt")) return qjsGlobalParseInt(ctx, output, global, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "parseFloat")) return qjsGlobalParseFloat(ctx, output, global, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "isNaN")) return qjsGlobalIsNaNOrFinite(ctx, output, global, this_value, args, true);
        if (std.mem.eql(u8, name, "isFinite")) return qjsGlobalIsNaNOrFinite(ctx, output, global, this_value, args, false);
        if (builtins.bigint.staticUnsignedMode(name)) |unsigned| {
            return qjsBigIntAsN(ctx, output, global, args, unsigned, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "RegExp")) return qjsRegExpFunctionCall(ctx, output, global, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "DisposableStack")) return error.TypeError;
        if (std.mem.eql(u8, name, "AsyncDisposableStack")) return error.TypeError;
        if (std.mem.eql(u8, name, "AggregateError")) {
            const prototype = try constructorPrototypeObject(ctx.runtime, func);
            const constructor_global = objectRealmGlobal(function_object) orelse global;
            return try qjsAggregateErrorConstructWithPrototype(ctx, output, constructor_global, prototype, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "SuppressedError")) {
            const prototype = try constructorPrototypeObject(ctx.runtime, func);
            return try qjsSuppressedErrorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
        }
        if (isErrorConstructorName(name)) {
            const prototype = try constructorPrototypeObject(ctx.runtime, func);
            return try qjsErrorConstructWithPrototype(ctx, output, global, name, prototype, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "isError")) return qjsErrorIsError(args);
        if (std.mem.eql(u8, name, "isView")) return qjsArrayBufferIsView(args);
        if (std.mem.eql(u8, name, "set")) {
            if (try qjsTypedArraySetCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        }
        if (try qjsUint8ArrayCodecCall(ctx, output, global, this_value, name, args, caller_function, caller_frame)) |value| return value;
        if (std.mem.eql(u8, name, "next")) {
            if (try qjsAsyncFromSyncIteratorMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
            if (try qjsIteratorHelperNext(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
            if (try qjsIteratorWrapNext(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
            if (isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object) and !isAsyncGeneratorReceiver(this_value)) return asyncGeneratorRejectedTypeError(ctx, global);
            if (try qjsGeneratorNext(ctx, output, global, this_value, args)) |value| return value;
            if (isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object)) return asyncGeneratorRejectedTypeError(ctx, global);
            if (try qjsRegExpStringIteratorNext(ctx, output, global, this_value, caller_function, caller_frame)) |value| return value;
            if (try qjsArrayIteratorNext(ctx, output, global, this_value, function_object)) |value| return value;
        }
        if (std.mem.eql(u8, name, "throw")) {
            if (isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object) and !isAsyncGeneratorReceiver(this_value)) return asyncGeneratorRejectedTypeError(ctx, global);
            if (try qjsGeneratorThrow(ctx, output, global, this_value, args)) |value| return value;
            if (isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object)) return asyncGeneratorRejectedTypeError(ctx, global);
        }
        if (std.mem.eql(u8, name, "[Symbol.iterator]")) {
            if (isIteratorIdentityFunction(ctx.runtime, function_object)) return this_value.dup();
            if (objectFromValue(this_value)) |this_object| {
                if (this_object.class_id == core.class.ids.array_iterator) return this_value.dup();
            }
        }
        if (std.mem.eql(u8, name, "[Symbol.asyncIterator]")) {
            return this_value.dup();
        }
        if (std.mem.eql(u8, name, "[Symbol.asyncDispose]")) {
            if (try qjsAsyncIteratorAsyncDispose(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "return")) {
            if (try qjsAsyncFromSyncIteratorMethodCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
            if (try qjsIteratorHelperReturn(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
            if (try qjsIteratorWrapReturn(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
            if (isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object) and !isAsyncGeneratorReceiver(this_value)) return asyncGeneratorRejectedTypeError(ctx, global);
            if (try qjsGeneratorReturn(ctx, output, global, this_value, args)) |value| return value;
            if (isAsyncGeneratorPrototypeMethod(ctx.runtime, function_object)) return asyncGeneratorRejectedTypeError(ctx, global);
        }
        if (std.mem.eql(u8, name, "fromCharCode")) {
            return qjsStringFromCharCode(ctx, output, global, args);
        }
        if (std.mem.eql(u8, name, "fromCodePoint")) {
            return qjsStringFromCodePoint(ctx, output, global, args);
        }
        if (std.mem.eql(u8, name, "raw")) {
            return qjsStringRaw(ctx, output, global, args, caller_function, caller_frame);
        }
        if (builtins.date.staticMethodId(name)) |method_id| {
            if (objectFromValue(this_value)) |receiver_object| {
                if (try constructorNameEqlLocal(ctx.runtime, receiver_object, "Date")) {
                    if (try date_vm.qjsDateStaticCall(ctx, output, global, this_value, method_id, args, caller_function, caller_frame)) |value| return value;
                    return builtins.date.staticCall(ctx.runtime, method_id, args) catch |err| switch (err) {
                        error.TypeError => error.TypeError,
                        else => err,
                    };
                }
            }
        }
        if (try qjsArrayIteratorMethod(ctx, global, this_value, function_object)) |value| {
            return value;
        }
        if (std.mem.eql(u8, name, "apply")) {
            if (!isCallableValue(this_value)) return throwFunctionRealmTypeError(ctx, global, function_object);
            const this_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const arg_array = if (args.len >= 2 and !args[1].isNull() and !args[1].isUndefined()) args[1] else {
                return callValueOrBytecode(ctx, output, global, this_arg, this_value, &.{}, caller_function, caller_frame);
            };
            if (!arg_array.isObject()) return throwFunctionRealmTypeError(ctx, global, function_object);
            if (callableObjectFromValue(this_value)) |target_object| {
                const target_name = try call_mod.nativeFunctionNameForVm(ctx.runtime, target_object);
                defer ctx.runtime.memory.allocator.free(target_name);
                if (std.mem.eql(u8, target_name, "fromCodePoint")) return qjsStringFromCodePointArray(ctx, output, global, arg_array);
            }
            var apply_args = try argsFromArrayLike(ctx, output, global, arg_array, caller_function, caller_frame);
            defer freeArgs(ctx.runtime, apply_args);
            var apply_args_root = ValueSliceRoot{};
            apply_args_root.init(ctx.runtime, &apply_args);
            defer apply_args_root.deinit();
            return callValueOrBytecode(ctx, output, global, this_arg, this_value, apply_args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "call")) {
            if (!isCallableValue(this_value)) return throwFunctionRealmTypeError(ctx, global, function_object);
            const this_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const call_args = if (args.len >= 1) args[1..] else &.{};
            return callValueOrBytecode(ctx, output, global, this_arg, this_value, call_args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "get __proto__")) return qjsObjectProtoGetterCall(ctx, output, global, this_value, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "set __proto__")) {
            const proto_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return qjsObjectProtoSetterCall(ctx, output, global, this_value, proto_arg, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "set")) {
            if (try qjsTypedArraySetCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "deref")) {
            return qjsWeakRefDeref(ctx.runtime, this_value);
        }
        if (std.mem.eql(u8, name, "join")) {
            if (try qjsArrayJoinCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "toString")) {
            if (try qjsArrayToStringCall(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "toLocaleString")) {
            if (try qjsArrayToLocaleStringCall(ctx, output, global, this_value, function_object, caller_function, caller_frame)) |value| return value;
        }
        if (try qjsArrayFromCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try qjsArrayOfCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try qjsArrayIterationCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try qjsArrayAtCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try qjsArrayReduceCall(ctx, output, global, this_value, func, args, false)) |value| return value;
        if (try qjsArrayReduceCall(ctx, output, global, this_value, func, args, true)) |value| return value;
        if (try qjsArraySearchCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try qjsArrayCopyWithinCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try qjsArrayFillCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try qjsArrayPushCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try qjsArrayPopCall(ctx, output, global, this_value, func, caller_function, caller_frame)) |value| return value;
        if (try qjsArrayShiftCall(ctx, output, global, this_value, func)) |value| return value;
        if (try qjsArrayUnshiftCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try qjsArrayReverseCall(ctx, output, global, this_value, func, caller_function, caller_frame)) |value| return value;
        if (try qjsArraySpliceCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try qjsTypedArraySliceSubarrayCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try qjsArraySliceCall(ctx, output, global, this_value, func, args)) |value| return value;
        if (try qjsArrayFlatCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try qjsArraySortCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try qjsArrayByCopyCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (try qjsArrayConcatCall(ctx, output, global, this_value, func, args, caller_function, caller_frame)) |value| return value;
        if (std.mem.eql(u8, name, "slice")) {
            if (try qjsGeneratorSlice(ctx, output, global, this_value, args)) |value| return value;
        }
        if (std.mem.eql(u8, name, "then") or std.mem.eql(u8, name, "catch") or std.mem.eql(u8, name, "finally")) {
            if (try qjsPromiseThen(ctx, output, global, this_value, name, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "eval")) {
            const eval_global = if (function_object.functionRealmGlobalSlot().*) |realm_value|
                property_ops.expectObject(realm_value) catch global
            else
                global;
            return indirectEval(ctx, output, eval_global, args);
        }
        if (std.mem.eql(u8, name, "throws")) return qjsAssertThrows(ctx, output, global, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "groupBy")) {
            if (try collection_vm.qjsMapGroupByCall(ctx, output, global, args, caller_function, caller_frame)) |grouped| return grouped;
        }
        if (std.mem.eql(u8, name, "getOrInsertComputed")) {
            if (try collection_vm.qjsMapGetOrInsertComputed(ctx, output, global, this_value, function_object, args, caller_function, caller_frame)) |value| return value;
        }
        if (getNumberPrototypeMethodId(ctx.runtime, function_object)) |method_id| {
            return qjsNumberPrototypeMethod(ctx, output, global, this_value, @intCast(method_id), args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "concat") and !isArrayMethodReceiver(this_value)) {
            return qjsStringConcat(ctx, output, global, this_value, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "replace")) {
            return qjsStringReplace(ctx, output, global, this_value, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "exec")) {
            if (try qjsRegExpExecMethod(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "test")) {
            if (try qjsRegExpTestMethod(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "compile")) {
            const compile_global = objectRealmGlobal(function_object) orelse global;
            if (try qjsRegExpCompile(ctx, output, compile_global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "[Symbol.search]")) {
            if (try qjsRegExpSymbolSearch(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "[Symbol.match]")) {
            if (try qjsRegExpSymbolMatch(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "[Symbol.matchAll]")) {
            if (try qjsRegExpSymbolMatchAll(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "[Symbol.replace]")) {
            if (try qjsRegExpSymbolReplace(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "[Symbol.split]")) {
            if (try qjsRegExpSymbolSplit(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
        }
        if (core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*)) |native_ref| {
            if (native_ref.domain == .regexp) {
                if (builtins.regexp.accessorNameFromId(native_ref.id)) |accessor_name| {
                    if (try qjsRegExpAccessor(ctx, output, global, this_value, func, accessor_name, caller_function, caller_frame)) |value| return value;
                    return builtins.regexp.accessor(ctx.runtime, this_value, accessor_name) catch |err| switch (err) {
                        error.TypeError => error.TypeError,
                        else => err,
                    };
                }
            }
        }
        if (builtins.regexp.accessorNameFromGetterName(name)) |accessor_name| {
            if (try qjsRegExpAccessor(ctx, output, global, this_value, func, accessor_name, caller_function, caller_frame)) |value| return value;
            return builtins.regexp.accessor(ctx.runtime, this_value, accessor_name) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        if (builtins.buffer.dataViewGetMethodId(name)) |method_id| {
            return qjsDataViewGet(ctx, output, global, this_value, method_id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                error.RangeError => error.RangeError,
                else => err,
            };
        }
        if (builtins.buffer.dataViewSetMethodId(name)) |method_id| {
            return qjsDataViewSet(ctx, output, global, this_value, method_id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                error.RangeError => error.RangeError,
                else => err,
            };
        }
        if (std.mem.eql(u8, name, "charAt")) {
            const index = if (args.len >= 1) args[0] else core.JSValue.int32(0);
            return builtins.string.charAtValue(ctx.runtime, this_value, index) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        if (std.mem.eql(u8, name, "[Symbol.iterator]")) {
            return qjsStringIterator(ctx, output, global, this_value, caller_function, caller_frame);
        }
        if (getStringPrototypeMethodId(ctx.runtime, function_object)) |method_id| {
            return qjsStringPrototypeMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        if (isStringMethodReceiver(this_value)) {
            if (standardStringMethodId(name)) |method_id| {
                return builtins.string.methodCall(ctx.runtime, this_value, method_id, args) catch |err| switch (err) {
                    error.TypeError => error.TypeError,
                    else => err,
                };
            }
        }
        if (annexBStringMethodId(name)) |method_id| {
            return qjsStringPrototypeMethod(ctx, output, global, this_value, method_id, args, caller_function, caller_frame) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        if (builtins.uri.methodId(name)) |mode| {
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const string_value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
            defer string_value.free(ctx.runtime);
            return builtins.uri.call(ctx.runtime, mode, string_value) catch |err| switch (err) {
                error.TypeError, error.URIError => err,
                else => err,
            };
        }
        if (std.mem.eql(u8, name, "escape")) {
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const string_value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
            defer string_value.free(ctx.runtime);
            return builtins.uri.escape(ctx.runtime, string_value);
        }
        if (std.mem.eql(u8, name, "unescape")) {
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const string_value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
            defer string_value.free(ctx.runtime);
            return builtins.uri.unescape(ctx.runtime, string_value);
        }
    }
    if (!isCallableValue(func)) return throwTypeErrorMessage(ctx, global, "not a function");
    return call_mod.callValueWithThisGlobalsAndGlobal(ctx, output, global, &.{}, this_value, func, args);
}

test "callValueOrBytecodeClassMode roots inline args before bytecode frame allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);
    fb.byte_code = try rt.memory.alloc(u8, 1);
    fb.byte_code[0] = op.return_undef;
    fb.byte_code_len = 1;
    fb.var_count = 1;

    var func_value = core.JSValue.functionBytecode(&fb.header);
    var func_alive = true;
    defer if (func_alive) func_value.free(rt);

    const arg_atom = try rt.atoms.newValueSymbol("gc-call-value-inline-arg-root");
    const args = [_]core.JSValue{core.JSValue.symbol(arg_atom)};

    const Trigger = struct {
        rt: *core.JSRuntime,
        atom_id: u32,
        saw_arg: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const saved_trigger_fn = self.rt.memory.trigger_gc_fn;
            const saved_trigger_ctx = self.rt.memory.trigger_gc_ctx;
            self.rt.memory.trigger_gc_fn = null;
            self.rt.memory.trigger_gc_ctx = null;
            defer {
                self.rt.memory.trigger_gc_fn = saved_trigger_fn;
                self.rt.memory.trigger_gc_ctx = saved_trigger_ctx;
            }
            var visitor = core.runtime.RootVisitor{
                .context = self,
                .visit_value = @This().visitValue,
                .visit_object = @This().visitObject,
            };
            self.rt.traceActiveRoots(&visitor) catch {
                self.trace_failed = true;
            };
        }

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.asSymbolAtom()) |atom_id| {
                if (atom_id == self.atom_id) self.saw_arg = true;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var trigger = Trigger{
        .rt = rt,
        .atom_id = arg_atom,
    };
    rt.memory.trigger_gc_fn = Trigger.trigger;
    rt.memory.trigger_gc_ctx = &trigger;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    const result = try callValueOrBytecodeClassMode(
        ctx,
        null,
        global,
        core.JSValue.undefinedValue(),
        func_value,
        &args,
        null,
        null,
        false,
    );
    defer result.free(rt);
    rt.memory.trigger_gc_fn = saved_trigger_fn;
    rt.memory.trigger_gc_ctx = saved_trigger_ctx;

    try std.testing.expect(!trigger.trace_failed);
    try std.testing.expect(trigger.saw_arg);

    func_value.free(rt);
    func_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(arg_atom) == null);
}

pub const SimpleNumericArg0Bytecode = struct {
    binop: u8,
    rhs: i32,
};

pub fn callSimpleNumericBytecode(
    rt: *core.JSRuntime,
    fb: *const bytecode.FunctionBytecode,
    args: []const core.JSValue,
    captures: []const core.JSValue,
) !?core.JSValue {
    switch (fb.simple_numeric_kind) {
        .arg0_const => {
            if (args.len == 0 or !args[0].isNumber()) return null;
            return try simpleNumericBinary(rt, fb.simple_numeric_op, args[0], core.JSValue.int32(fb.simple_numeric_rhs));
        },
        .arg0_arg1 => {
            if (args.len < 2 or !args[0].isNumber() or !args[1].isNumber()) return null;
            return try simpleNumericBinary(rt, fb.simple_numeric_op, args[0], args[1]);
        },
        .capture0_arg0 => {
            if (args.len == 0 or !args[0].isNumber() or captures.len == 0) return null;
            const captured = slotValueBorrow(captures[0]);
            if (!captured.isNumber()) return null;
            return try simpleNumericBinary(rt, fb.simple_numeric_op, captured, args[0]);
        },
        .capture0_post_inc_return => return try callSimpleCapture0PostIncReturn(rt, captures),
        .none => {},
    }
    return null;
}

fn callSimpleCapture0PostIncReturn(rt: *core.JSRuntime, captures: []const core.JSValue) !?core.JSValue {
    if (captures.len == 0) return null;
    const cell = varRefCellFromValue(captures[0]) orelse return null;
    if (cell.varRefIsDeletedSlot().* or cell.varRefIsFunctionNameSlot().* or cell.varRefIsConstSlot().*) return null;
    const slot = cell.varRefValueSlot();
    const current_value = slot.* orelse return null;
    const current = current_value.asInt32() orelse return null;
    const updated = simpleInt32Add(current, 1);
    try cell.setVarRefValue(rt, updated);
    return updated;
}

pub fn simpleNumericCapture0Arg0Bytecode(fb: *const bytecode.FunctionBytecode) ?u8 {
    if (fb.is_class_constructor or fb.func_kind != .normal) return null;
    if (fb.var_count != 0 or fb.cpool_count != 0) return null;
    if (fb.byte_code.len != 4) return null;
    if (fb.byte_code[0] != op.get_var_ref0 or fb.byte_code[1] != op.get_arg0) return null;
    const binop = fb.byte_code[2];
    switch (binop) {
        op.add, op.sub, op.mul, op.div, op.mod => {},
        else => return null,
    }
    if (fb.byte_code[3] != op.@"return") return null;
    return binop;
}

pub fn simpleNumericArg0Arg1Bytecode(fb: *const bytecode.FunctionBytecode) ?u8 {
    if (fb.is_class_constructor or fb.func_kind != .normal) return null;
    if (fb.var_count != 0 or fb.var_ref_count != 0 or fb.cpool_count != 0) return null;
    if (fb.byte_code.len != 4) return null;
    if (fb.byte_code[0] != op.get_arg0 or fb.byte_code[1] != op.get_arg1) return null;
    const binop = fb.byte_code[2];
    switch (binop) {
        op.add, op.sub, op.mul, op.div, op.mod => {},
        else => return null,
    }
    if (fb.byte_code[3] != op.@"return") return null;
    return binop;
}

pub fn callSimpleNumericArg0Bytecode(
    rt: *core.JSRuntime,
    fb: *const bytecode.FunctionBytecode,
    args: []const core.JSValue,
) !?core.JSValue {
    if (args.len == 0 or !args[0].isNumber()) return null;
    const simple = cachedSimpleNumericArg0Bytecode(fb) orelse simpleNumericArg0Bytecode(fb) orelse return null;
    return try simpleNumericBinary(rt, simple.binop, args[0], core.JSValue.int32(simple.rhs));
}

pub fn cachedSimpleNumericArg0Bytecode(fb: *const bytecode.FunctionBytecode) ?SimpleNumericArg0Bytecode {
    if (fb.simple_numeric_kind != .arg0_const) return null;
    return .{ .binop = fb.simple_numeric_op, .rhs = fb.simple_numeric_rhs };
}

pub fn simpleNumericArg0Bytecode(fb: *const bytecode.FunctionBytecode) ?SimpleNumericArg0Bytecode {
    if (fb.is_class_constructor or fb.func_kind != .normal) return null;
    if (fb.var_count != 0 or fb.var_ref_count != 0 or fb.cpool_count != 0) return null;
    if (fb.byte_code.len < 4 or fb.byte_code[0] != op.get_arg0) return null;

    var pc: usize = 1;
    const rhs = simpleInlineIntConstant(fb.byte_code, &pc) orelse return null;
    if (pc >= fb.byte_code.len) return null;
    const binop = fb.byte_code[pc];
    pc += 1;
    switch (binop) {
        op.add, op.sub, op.mul, op.div, op.mod => {},
        else => return null,
    }
    if (pc >= fb.byte_code.len or fb.byte_code[pc] != op.@"return") return null;
    pc += 1;
    if (pc != fb.byte_code.len) return null;
    return .{ .binop = binop, .rhs = rhs };
}

pub fn simpleInlineIntConstant(code: []const u8, pc: *usize) ?i32 {
    if (pc.* >= code.len) return null;
    const opcode_id = code[pc.*];
    pc.* += 1;
    return switch (opcode_id) {
        op.push_minus1 => -1,
        op.push_0 => 0,
        op.push_1 => 1,
        op.push_2 => 2,
        op.push_3 => 3,
        op.push_4 => 4,
        op.push_5 => 5,
        op.push_6 => 6,
        op.push_7 => 7,
        op.push_i8 => blk: {
            if (pc.* >= code.len) return null;
            const value: i8 = @bitCast(code[pc.*]);
            pc.* += 1;
            break :blk @as(i32, value);
        },
        op.push_i16 => blk: {
            if (pc.* + 2 > code.len) return null;
            const value = std.mem.readInt(i16, code[pc.*..][0..2], .little);
            pc.* += 2;
            break :blk @as(i32, value);
        },
        else => null,
    };
}

pub fn simpleNumericBinary(rt: *core.JSRuntime, binop: u8, lhs: core.JSValue, rhs: core.JSValue) !core.JSValue {
    if (lhs.asInt32()) |lhs_int| {
        if (rhs.asInt32()) |rhs_int| {
            return switch (binop) {
                op.add => simpleInt32Add(lhs_int, rhs_int),
                op.sub => simpleInt32Sub(lhs_int, rhs_int),
                op.mul => simpleInt32Mul(lhs_int, rhs_int),
                else => try value_ops.binary(rt, binop, lhs, rhs),
            };
        }
    }
    return try value_ops.binary(rt, binop, lhs, rhs);
}

pub fn simpleInt32Add(lhs: i32, rhs: i32) core.JSValue {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) + @as(f64, @floatFromInt(rhs)));
}

pub fn simpleInt32Sub(lhs: i32, rhs: i32) core.JSValue {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) - @as(f64, @floatFromInt(rhs)));
}

pub fn simpleInt32Mul(lhs: i32, rhs: i32) core.JSValue {
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) * @as(f64, @floatFromInt(rhs)));
}

pub fn classConstructorNewTarget(func: core.JSValue, caller_frame: ?*frame_mod.Frame) core.JSValue {
    if (caller_frame) |frame| {
        if (!frame.new_target.isUndefined()) return frame.new_target;
    }
    return func;
}

pub fn constructBuiltinSuperConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    explicit_new_target: ?core.JSValue,
) !?core.JSValue {
    if (std.mem.eql(u8, name, "Symbol") or std.mem.eql(u8, name, "BigInt")) return error.TypeError;

    const new_target = explicit_new_target orelse classConstructorNewTarget(constructor, caller_frame);

    if (std.mem.eql(u8, name, "Promise")) {
        const executor = if (args.len >= 1) args[0] else return error.TypeError;
        if (!isCallableValue(executor)) return error.TypeError;
    }
    if (std.mem.eql(u8, name, "Iterator")) {
        if (builtins.object.sameValue(new_target, constructor)) return error.TypeError;
        const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
        return instance.value();
    }

    if (std.mem.eql(u8, name, "Function")) return try constructDynamicFunctionFromSource(ctx, output, global, constructor, new_target, args, .normal, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "AsyncFunction")) return try constructDynamicFunctionFromSource(ctx, output, global, constructor, new_target, args, .async_function, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "GeneratorFunction")) return try constructDynamicFunctionFromSource(ctx, output, global, constructor, new_target, args, .generator, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "AsyncGeneratorFunction")) return try constructDynamicFunctionFromSource(ctx, output, global, constructor, new_target, args, .async_generator, caller_function, caller_frame);

    if (std.mem.eql(u8, name, "ArrayBuffer") or std.mem.eql(u8, name, "SharedArrayBuffer")) {
        const byte_length = if (args.len >= 1)
            try qjsTypedArrayConstructToIndex(ctx, output, global, args[0])
        else
            @as(usize, 0);
        const max_byte_length = try qjsArrayBufferMaxByteLengthOption(ctx, output, global, args, byte_length);
        const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "SharedArrayBuffer")) {
            return try builtins.buffer.sharedArrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
        }
        return try builtins.buffer.arrayBufferConstructLength(ctx.runtime, byte_length, max_byte_length, prototype);
    }

    if (std.mem.eql(u8, name, "DataView")) {
        const coerced = try qjsDataViewConstructorArgs(ctx, output, global, args);
        const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
        return try qjsDataViewConstructWithPrototype(ctx.runtime, args[0], coerced, prototype);
    }

    if (std.mem.eql(u8, name, "RegExp")) {
        return try qjsRegExpConstructCall(ctx, output, global, new_target, args, caller_function, caller_frame);
    }

    const prototype = try reflectConstructPrototypeVm(ctx, output, global, name, new_target, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Object")) {
        if (builtins.object.sameValue(new_target, constructor) and args.len >= 1 and args[0].isObject()) return args[0].dup();
        const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
        return instance.value();
    }
    if (std.mem.eql(u8, name, "Array")) return builtins.array.constructConstructorWithPrototype(ctx.runtime, args, prototype) catch |err| switch (err) {
        error.RangeError => return @as(?core.JSValue, try throwRangeErrorMessage(ctx, global, "invalid array length")),
        else => err,
    };
    if (std.mem.eql(u8, name, "String")) return try qjsStringConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Number")) {
        if (args.len >= 1 and args[0].isSymbol()) return error.TypeError;
        const primitive = if (args.len >= 1) try value_ops.toNumberValue(ctx.runtime, args[0]) else core.JSValue.int32(0);
        return try constructPrimitiveWrapperWithPrototype(ctx.runtime, core.class.ids.number, prototype, primitive);
    }
    if (std.mem.eql(u8, name, "Boolean")) {
        return try constructPrimitiveWrapperWithPrototype(ctx.runtime, core.class.ids.boolean, prototype, core.JSValue.boolean(args.len >= 1 and valueTruthy(args[0])));
    }
    if (std.mem.eql(u8, name, "Date")) return try date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype, args);
    if (std.mem.eql(u8, name, "AggregateError")) {
        const constructor_global = if (objectFromValue(constructor)) |constructor_object|
            objectRealmGlobal(constructor_object) orelse global
        else
            global;
        return try qjsAggregateErrorConstructWithPrototype(ctx, output, constructor_global, prototype, args, caller_function, caller_frame);
    }
    if (std.mem.eql(u8, name, "SuppressedError")) return try qjsSuppressedErrorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
    if (isErrorConstructorName(name)) return try qjsErrorConstructWithPrototype(ctx, output, global, name, prototype, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "Promise")) return try qjsPromiseConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
    if (std.mem.eql(u8, name, "WeakRef")) {
        const target = if (args.len >= 1) args[0] else return error.TypeError;
        if (!qjsCanBeHeldWeakly(ctx.runtime, target)) return error.TypeError;
        return try qjsConstructWeakRefWithPrototype(ctx.runtime, target, prototype);
    }
    if (std.mem.eql(u8, name, "FinalizationRegistry")) {
        const cleanup_callback = if (args.len >= 1) args[0] else return error.TypeError;
        if (!isCallableValue(cleanup_callback)) return error.TypeError;
        return try qjsConstructFinalizationRegistryWithPrototype(ctx.runtime, cleanup_callback, prototype);
    }
    if (std.mem.eql(u8, name, "DisposableStack")) return try qjsDisposableStackConstructWithPrototype(ctx, global, prototype);
    if (std.mem.eql(u8, name, "AsyncDisposableStack")) return try qjsAsyncDisposableStackConstructWithPrototype(ctx, global, prototype);
    if (builtins.collection.constructorId(name)) |kind| return try constructCollectionWithPrototypeFromVm(ctx, output, global, kind, args, prototype);
    if (std.mem.eql(u8, name, "DataView")) return try builtins.buffer.dataViewConstruct(ctx.runtime, args, prototype);
    if (construct_mod.typedArrayElement(name)) |element| return try construct_mod.constructTypedArrayValue(ctx.runtime, prototype, element, args, global);

    return null;
}

pub const disposable_ops = @import("disposable_ops.zig");
pub const DisposableStackMethod = disposable_ops.DisposableStackMethod;
pub const disposableStackMethodFromMarker = disposable_ops.disposableStackMethodFromMarker;
pub const disposableStackReceiver = disposable_ops.disposableStackReceiver;
pub const parserDisposableStackReceiver = disposable_ops.parserDisposableStackReceiver;
pub const qjsDisposableStackMethodCall = disposable_ops.qjsDisposableStackMethodCall;
pub const qjsDisposableStackUse = disposable_ops.qjsDisposableStackUse;
pub const qjsDisposableStackAdopt = disposable_ops.qjsDisposableStackAdopt;
pub const qjsDisposableStackDefer = disposable_ops.qjsDisposableStackDefer;
pub const qjsDisposableStackDispose = disposable_ops.qjsDisposableStackDispose;
pub const qjsDisposableStackRecordDisposeError = disposable_ops.qjsDisposableStackRecordDisposeError;
pub const qjsDisposeDisposableStackResources = disposable_ops.qjsDisposeDisposableStackResources;
pub const qjsUsingCreateDisposableStack = disposable_ops.qjsUsingCreateDisposableStack;
pub const qjsUsingAddSyncResource = disposable_ops.qjsUsingAddSyncResource;
pub const qjsUsingDisposeSyncStack = disposable_ops.qjsUsingDisposeSyncStack;
pub const qjsUsingDisposeSyncStackForThrow = disposable_ops.qjsUsingDisposeSyncStackForThrow;
pub const qjsDisposeResource = disposable_ops.qjsDisposeResource;
pub const runtimeErrorValueForDisposableDispose = disposable_ops.runtimeErrorValueForDisposableDispose;
pub const qjsSuppressedErrorForDispose = disposable_ops.qjsSuppressedErrorForDispose;
pub const qjsDisposableStackMove = disposable_ops.qjsDisposableStackMove;

pub fn defineErrorStack(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, instance: *core.Object) !void {
    const stack_value = try buildErrorStackValue(ctx, output, global, instance.value(), null);
    defer stack_value.free(ctx.runtime);
    try defineDataProperty(ctx.runtime, instance, "stack", stack_value, true, false, true);
}

pub fn captureErrorStack(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, instance: *core.Object) !void {
    _ = output;
    const sites = try buildCallSiteArray(ctx, global, null);
    defer sites.free(ctx.runtime);
    try instance.setErrorStackSites(ctx.runtime, sites);
}

pub fn buildErrorStackValue(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, error_value: core.JSValue, skip_name: ?[]const u8) !core.JSValue {
    if (ctx.formatting_error_stack) return buildErrorStackStringValue(ctx, global, skip_name);

    if (try errorPrepareStackTrace(ctx.runtime, global)) |prepare| {
        defer prepare.free(ctx.runtime);
        const sites = try buildCallSiteArray(ctx, global, skip_name);
        defer sites.free(ctx.runtime);
        ctx.formatting_error_stack = true;
        defer ctx.formatting_error_stack = false;
        return callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), prepare, &.{ error_value, sites }, null, null) catch |err| {
            if (exception_ops.pendingExceptionMatchesError(ctx, err)) {
                const thrown_value = ctx.takeException();
                thrown_value.free(ctx.runtime);
                return core.JSValue.nullValue();
            }
            if (ctx.hasException()) ctx.clearException();
            if (exception_ops.runtimeErrorInfo(err) != null) return core.JSValue.nullValue();
            return err;
        };
    }
    return buildErrorStackStringValue(ctx, global, skip_name);
}

pub fn formatCapturedErrorStackValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    error_value: core.JSValue,
    sites_value: core.JSValue,
    site_count: usize,
) !core.JSValue {
    if (ctx.formatting_error_stack) return formatCapturedErrorStackStringValue(ctx, sites_value, site_count);

    if (try errorPrepareStackTrace(ctx.runtime, global)) |prepare| {
        defer prepare.free(ctx.runtime);
        const sites_arg = sites_value.dup();
        defer sites_arg.free(ctx.runtime);
        ctx.formatting_error_stack = true;
        defer ctx.formatting_error_stack = false;
        return callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), prepare, &.{ error_value, sites_arg }, null, null) catch |err| {
            if (exception_ops.pendingExceptionMatchesError(ctx, err)) {
                const thrown_value = ctx.takeException();
                thrown_value.free(ctx.runtime);
                return core.JSValue.nullValue();
            }
            if (ctx.hasException()) ctx.clearException();
            if (exception_ops.runtimeErrorInfo(err) != null) return core.JSValue.nullValue();
            return err;
        };
    }
    return formatCapturedErrorStackStringValue(ctx, sites_value, site_count);
}

pub fn errorPrepareStackTrace(rt: *core.JSRuntime, global: *core.Object) !?core.JSValue {
    const error_key = try rt.internAtom("Error");
    defer rt.atoms.free(error_key);
    const error_value = global.getProperty(error_key);
    defer error_value.free(rt);
    const error_object = property_ops.expectObject(error_value) catch return null;
    const prepare_key = try rt.internAtom("prepareStackTrace");
    defer rt.atoms.free(prepare_key);
    const prepare = error_object.getProperty(prepare_key);
    if (!isCallableValue(prepare)) {
        prepare.free(rt);
        return null;
    }
    return prepare;
}

pub fn backtraceFunctionNameEql(ctx: *core.JSContext, entry: core.BacktraceFrame, expected: []const u8) bool {
    return std.mem.eql(u8, callSiteFunctionName(ctx, entry), expected);
}

pub fn callSiteFunctionName(ctx: *core.JSContext, entry: core.BacktraceFrame) []const u8 {
    const name = ctx.runtime.atoms.name(entry.function_name) orelse "";
    const file = ctx.runtime.atoms.name(entry.filename) orelse "";
    if (name.len == 0 or std.mem.eql(u8, name, file)) return "<anonymous>";
    return name;
}

pub fn callSiteFunctionNameValue(ctx: *core.JSContext, entry: core.BacktraceFrame) !core.JSValue {
    const name = ctx.runtime.atoms.name(entry.function_name) orelse "";
    const file = ctx.runtime.atoms.name(entry.filename) orelse "";
    if (name.len == 0 or std.mem.eql(u8, name, file)) return core.JSValue.nullValue();
    return value_ops.createStringValue(ctx.runtime, name);
}

pub fn errorStackTraceLimit(rt: *core.JSRuntime, global: *core.Object) usize {
    const error_key = rt.internAtom("Error") catch return 10;
    defer rt.atoms.free(error_key);
    const error_value = global.getProperty(error_key);
    defer error_value.free(rt);
    const error_object = property_ops.expectObject(error_value) catch return 10;
    const limit_key = rt.internAtom("stackTraceLimit") catch return 10;
    defer rt.atoms.free(limit_key);
    const limit_value = error_object.getProperty(limit_key);
    defer limit_value.free(rt);
    if (limit_value.isUndefined() or limit_value.isNull()) return 0;
    const number = value_ops.numberValue(limit_value) orelse return 10;
    if (!std.math.isFinite(number) or number <= 0) return 0;
    const truncated = @floor(number);
    if (truncated > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(truncated);
}

pub fn appendBacktraceFunctionName(
    ctx: *core.JSContext,
    bytes: *std.ArrayList(u8),
    function_name: core.Atom,
    filename: core.Atom,
) !void {
    const name = ctx.runtime.atoms.name(function_name) orelse "";
    const file = ctx.runtime.atoms.name(filename) orelse "";
    if (name.len == 0 or std.mem.eql(u8, name, file)) {
        try bytes.appendSlice(ctx.runtime.memory.allocator, "<anonymous>");
    } else {
        try bytes.appendSlice(ctx.runtime.memory.allocator, name);
    }
}

pub fn appendCallSiteFunctionName(rt: *core.JSRuntime, bytes: *std.ArrayList(u8), site: *core.Object) !void {
    const name_value = site.callSiteFunctionName() orelse {
        try bytes.appendSlice(rt.memory.allocator, "<anonymous>");
        return;
    };
    if (!name_value.isString()) {
        try bytes.appendSlice(rt.memory.allocator, "<anonymous>");
        return;
    }
    try value_ops.appendRawString(rt, bytes, name_value);
}

pub fn appendCallSiteFileName(rt: *core.JSRuntime, bytes: *std.ArrayList(u8), site: *core.Object) !void {
    const file_value = site.callSiteFile() orelse {
        try bytes.appendSlice(rt.memory.allocator, "<anonymous>");
        return;
    };
    if (!file_value.isString()) {
        try bytes.appendSlice(rt.memory.allocator, "<anonymous>");
        return;
    }
    try value_ops.appendRawString(rt, bytes, file_value);
}

pub fn currentArrowLexicalSuperThis(rt: *core.JSRuntime, frame: *frame_mod.Frame) ?core.JSValue {
    const current_object = currentArrowFunctionObject(frame) orelse return null;
    if (current_object.functionLexicalThisSlot().*) |this_value| return slotValueDup(this_value);
    _ = rt;
    return null;
}

pub fn currentArrowConstructorThis(rt: *core.JSRuntime, frame: *frame_mod.Frame) ?core.JSValue {
    const current_object = currentArrowFunctionObject(frame) orelse return null;
    _ = rt;
    const stored = current_object.functionArrowConstructorThis() orelse return null;
    return stored.dup();
}

pub fn setCurrentArrowLexicalThis(ctx: *core.JSContext, frame: *frame_mod.Frame, value: core.JSValue) !void {
    const current_object = currentArrowFunctionObject(frame) orelse {
        value.free(ctx.runtime);
        return;
    };
    if (current_object.functionLexicalThisSlot().*) |slot| {
        if (varRefCellFromValue(slot)) |cell| {
            try cell.setVarRefValue(ctx.runtime, value);
            return;
        }
        try current_object.setOptionalValueSlot(ctx.runtime, current_object.functionLexicalThisSlot(), value);
        return;
    }
    try current_object.setOptionalValueSlot(ctx.runtime, current_object.functionLexicalThisSlot(), value);
}

pub fn isCurrentSuperConstructor(ctx: *core.JSContext, frame: *frame_mod.Frame, func: core.JSValue) bool {
    _ = ctx;
    if (!frame.current_function.isObject()) return false;
    const current_object = property_ops.expectObject(frame.current_function) catch return false;
    const super_constructor = current_object.functionSuperConstructor() orelse return false;
    if (current_object.functionLexicalThisSlot().* == null) {
        if (current_object.getPrototype()) |prototype| {
            if (sameObjectIdentity(prototype.value(), func)) return true;
        }
    }
    return sameObjectIdentity(super_constructor, func);
}

pub fn qjsUriCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    mode: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (input.isString()) {
        return builtins.uri.call(ctx.runtime, mode, input) catch |err| switch (err) {
            error.TypeError, error.URIError => err,
            else => err,
        };
    }
    const string_value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    return builtins.uri.call(ctx.runtime, mode, string_value) catch |err| switch (err) {
        error.TypeError, error.URIError => err,
        else => err,
    };
}

pub fn qjsJsonCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const json_mod = builtins.json;
    return switch (id) {
        @intFromEnum(json_mod.StaticMethod.is_raw_json) => core.JSValue.boolean(args.len >= 1 and json_mod.isRawJSON(args[0])),
        @intFromEnum(json_mod.StaticMethod.raw_json) => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return json_mod.rawJSON(ctx.runtime, value) catch |err| switch (err) {
                error.SyntaxError, error.TypeError => err,
                else => err,
            };
        },
        @intFromEnum(json_mod.StaticMethod.parse) => {
            if (try json_vm.qjsJsonParseCall(ctx, output, global, args, caller_function, caller_frame)) |value| return value;
            return error.TypeError;
        },
        @intFromEnum(json_mod.StaticMethod.stringify) => {
            if (try json_vm.qjsJsonStringifyCall(ctx, output, global, args, caller_function, caller_frame)) |value| return value;
            return error.TypeError;
        },
        else => error.TypeError,
    };
}

pub fn toUint16CodeUnit(number: f64) u16 {
    if (std.math.isNan(number) or !std.math.isFinite(number) or number == 0) return 0;
    const int = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const modulo = @mod(int, 65536.0);
    return @intFromFloat(modulo);
}

pub fn qjsRegExpFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input_pattern = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const input_flags = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const pattern_is_regexp = try isRegExpObservable(ctx, output, global, input_pattern, caller_function, caller_frame);
    if (pattern_is_regexp and input_flags.isUndefined()) {
        const ctor_key = try ctx.runtime.internAtom("constructor");
        defer ctx.runtime.atoms.free(ctor_key);
        const pattern_constructor = try getValueProperty(ctx, output, global, input_pattern, ctor_key, caller_function, caller_frame);
        defer pattern_constructor.free(ctx.runtime);
        const regexp_key = try ctx.runtime.internAtom("RegExp");
        defer ctx.runtime.atoms.free(regexp_key);
        const regexp_ctor = global.getProperty(regexp_key);
        defer regexp_ctor.free(ctx.runtime);
        if (sameObjectIdentity(pattern_constructor, regexp_ctor)) return input_pattern.dup();
    }

    var owned_source: ?core.JSValue = null;
    defer if (owned_source) |value| value.free(ctx.runtime);
    var owned_pattern: ?core.JSValue = null;
    defer if (owned_pattern) |value| value.free(ctx.runtime);
    var pattern = if (args.len >= 1) args[0] else blk: {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_pattern = empty;
        break :blk empty;
    };
    if (pattern_is_regexp) {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id != core.class.ids.regexp) {
                const source = try getValueProperty(ctx, output, global, pattern, core.atom.ids.source, caller_function, caller_frame);
                owned_source = source;
                pattern = source;
            }
        }
    }
    if (pattern.isObject() and !pattern_is_regexp) {
        const pattern_object = objectFromValue(pattern) orelse return error.TypeError;
        if (pattern_object.class_id != core.class.ids.regexp) {
            const string_value = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
            owned_pattern = string_value;
            pattern = string_value;
        }
    }

    var owned_flags: ?core.JSValue = null;
    defer if (owned_flags) |value| value.free(ctx.runtime);
    var flags = if (!input_flags.isUndefined())
        input_flags
    else if (pattern_is_regexp) blk: {
        const pattern_object = objectFromValue(input_pattern) orelse break :blk input_flags;
        if (pattern_object.class_id == core.class.ids.regexp) break :blk input_flags;
        const flags_key = try ctx.runtime.internAtom("flags");
        defer ctx.runtime.atoms.free(flags_key);
        const pattern_flags = try getValueProperty(ctx, output, global, input_pattern, flags_key, caller_function, caller_frame);
        owned_flags = pattern_flags;
        break :blk pattern_flags;
    } else blk: {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_flags = empty;
        break :blk empty;
    };
    if (!flags.isUndefined() and flags.isObject()) {
        const string_value = try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
        if (owned_flags) |old| old.free(ctx.runtime);
        owned_flags = string_value;
        flags = string_value;
    }

    return builtins.regexp.constructWithPrototype(ctx.runtime, pattern, flags, constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"));
}

pub fn qjsRegExpConstructCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input_pattern = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const input_flags = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if ((input_pattern.isString() or input_pattern.isUndefined()) and
        (input_flags.isString() or input_flags.isUndefined()))
    {
        if (input_pattern.isString()) {
            if (latin1StringSlice(input_pattern)) |pattern_bytes| {
                const flag_bytes: ?[]const u8 = if (input_flags.isUndefined()) "" else latin1StringSlice(input_flags);
                if (flag_bytes) |flags| {
                    if (canConstructRegExpFromBorrowedLatin1(pattern_bytes)) {
                        const prototype = try reflectConstructPrototypeVm(ctx, output, global, "RegExp", new_target, caller_function, caller_frame);
                        return builtins.regexp.constructLiteral(ctx.runtime, pattern_bytes, flags, prototype);
                    }
                }
            }
        }
        const prototype = try reflectConstructPrototypeVm(ctx, output, global, "RegExp", new_target, caller_function, caller_frame);
        return builtins.regexp.constructWithPrototype(ctx.runtime, input_pattern, input_flags, prototype);
    }
    const pattern_is_regexp = try isRegExpObservable(ctx, output, global, input_pattern, caller_function, caller_frame);

    var owned_source: ?core.JSValue = null;
    defer if (owned_source) |value| value.free(ctx.runtime);
    var owned_pattern: ?core.JSValue = null;
    defer if (owned_pattern) |value| value.free(ctx.runtime);
    var pattern = if (args.len >= 1) args[0] else blk: {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_pattern = empty;
        break :blk empty;
    };
    if (pattern.isUndefined()) {
        const empty = try value_ops.createStringValue(ctx.runtime, "");
        owned_pattern = empty;
        pattern = empty;
    } else if (pattern_is_regexp) {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                const source = try regexpInternalStringValue(pattern_object, true);
                owned_source = source;
                pattern = source;
            } else {
                const source = try getValueProperty(ctx, output, global, pattern, core.atom.ids.source, caller_function, caller_frame);
                owned_source = source;
                pattern = source;
            }
        }
    } else if (pattern.isObject()) {
        const pattern_object = objectFromValue(pattern) orelse return error.TypeError;
        if (pattern_object.class_id != core.class.ids.regexp) {
            const string_value = try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
            owned_pattern = string_value;
            pattern = string_value;
        }
    }

    var owned_flags: ?core.JSValue = null;
    defer if (owned_flags) |value| value.free(ctx.runtime);
    var flags = if (!input_flags.isUndefined())
        input_flags
    else if (pattern_is_regexp) blk: {
        const pattern_object = objectFromValue(input_pattern) orelse break :blk core.JSValue.undefinedValue();
        if (pattern_object.class_id == core.class.ids.regexp) {
            const pattern_flags = try regexpInternalStringValue(pattern_object, false);
            owned_flags = pattern_flags;
            break :blk pattern_flags;
        }
        const flags_key = try ctx.runtime.internAtom("flags");
        defer ctx.runtime.atoms.free(flags_key);
        const pattern_flags = try getValueProperty(ctx, output, global, input_pattern, flags_key, caller_function, caller_frame);
        owned_flags = pattern_flags;
        break :blk pattern_flags;
    } else core.JSValue.undefinedValue();
    if (!flags.isUndefined() and flags.isObject()) {
        const string_value = try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
        if (owned_flags) |old| old.free(ctx.runtime);
        owned_flags = string_value;
        flags = string_value;
    }

    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "RegExp", new_target, caller_function, caller_frame);
    return builtins.regexp.constructWithPrototype(ctx.runtime, pattern, flags, prototype);
}

pub fn qjsRegExpExecMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const regexp_object = property_ops.expectObject(this_value) catch {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    };
    if (regexp_object.class_id != core.class.ids.regexp) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    }
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    var owned_string: ?core.JSValue = null;
    defer if (owned_string) |value| value.free(ctx.runtime);
    const string_value = if (input.isString()) input else blk: {
        const value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
        owned_string = value;
        break :blk value;
    };
    return qjsRegExpExecResult(ctx, output, global, this_value, regexp_object, string_value, true, caller_function, caller_frame);
}

pub fn qjsRegExpTestMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const receiver_object = property_ops.expectObject(this_value) catch {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    };
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    var owned_string: ?core.JSValue = null;
    defer if (owned_string) |value| value.free(ctx.runtime);
    const string_value = if (input.isString()) input else blk: {
        const value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
        owned_string = value;
        break :blk value;
    };
    const exec_atom = core.atom.predefinedId("exec", .string) orelse return error.TypeError;
    if (qjsRegExpPrototypeMethodIsDefault(receiver_object, exec_atom, @intFromEnum(builtins.regexp.PrototypeMethod.exec))) {
        if (try qjsRegExpTestFastNoResult(ctx, receiver_object, string_value)) |matched| {
            return core.JSValue.boolean(matched);
        }
        const result = try qjsRegExpExecResult(ctx, output, global, this_value, receiver_object, string_value, true, caller_function, caller_frame) orelse return core.JSValue.boolean(false);
        defer result.free(ctx.runtime);
        return core.JSValue.boolean(!result.isNull());
    }

    const result = try qjsRegExpExecGeneric(ctx, output, global, this_value, string_value, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    return core.JSValue.boolean(!result.isNull());
}

pub fn qjsRegExpNativeCallById(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    this_value: core.JSValue,
    native_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return switch (native_id) {
        @intFromEnum(builtins.regexp.StaticMethod.escape) => try builtins.regexp.escape(ctx.runtime, args),
        @intFromEnum(builtins.regexp.PrototypeMethod.to_string) => try qjsRegExpToString(ctx, output, global, this_value, caller_function, caller_frame),
        @intFromEnum(builtins.regexp.PrototypeMethod.exec) => try qjsRegExpExecMethod(ctx, output, global, this_value, args, caller_function, caller_frame),
        @intFromEnum(builtins.regexp.PrototypeMethod.test_) => try qjsRegExpTestMethod(ctx, output, global, this_value, args, caller_function, caller_frame),
        @intFromEnum(builtins.regexp.PrototypeMethod.compile) => blk: {
            const function_object = objectFromValue(func) orelse break :blk try qjsRegExpCompile(ctx, output, global, this_value, args, caller_function, caller_frame);
            const compile_global = objectRealmGlobal(function_object) orelse global;
            break :blk try qjsRegExpCompile(ctx, output, compile_global, this_value, args, caller_function, caller_frame);
        },
        @intFromEnum(builtins.regexp.PrototypeMethod.symbol_search) => try qjsRegExpSymbolSearch(ctx, output, global, this_value, args, caller_function, caller_frame),
        @intFromEnum(builtins.regexp.PrototypeMethod.symbol_match) => try qjsRegExpSymbolMatch(ctx, output, global, this_value, args, caller_function, caller_frame),
        @intFromEnum(builtins.regexp.PrototypeMethod.symbol_match_all) => try qjsRegExpSymbolMatchAll(ctx, output, global, this_value, args, caller_function, caller_frame),
        @intFromEnum(builtins.regexp.PrototypeMethod.symbol_replace) => try qjsRegExpSymbolReplace(ctx, output, global, this_value, args, caller_function, caller_frame),
        @intFromEnum(builtins.regexp.PrototypeMethod.symbol_split) => try qjsRegExpSymbolSplit(ctx, output, global, this_value, args, caller_function, caller_frame),
        else => blk: {
            if (builtins.regexp.legacyAccessorMethodFromId(native_id)) |method| {
                const function_object = objectFromValue(func) orelse return error.TypeError;
                break :blk try qjsRegExpLegacyAccessor(ctx, output, global, this_value, function_object, method, args, caller_function, caller_frame);
            }
            if (builtins.regexp.accessorNameFromId(native_id)) |accessor_name| {
                if (try qjsRegExpAccessor(ctx, output, global, this_value, func, accessor_name, caller_function, caller_frame)) |value| break :blk value;
                break :blk builtins.regexp.accessor(ctx.runtime, this_value, accessor_name) catch |err| switch (err) {
                    error.TypeError => error.TypeError,
                    else => err,
                };
            }
            break :blk null;
        },
    };
}

pub const RegExpBorrowedSourceFlags = struct {
    source: []const u8,
    flags: []const u8,
};

pub fn qjsRegExpTestFastNoResult(
    ctx: *core.JSContext,
    regexp_object: *core.Object,
    string_value: core.JSValue,
) !?bool {
    if (!regExpLastIndexCanSkipCoercion(regexp_object)) return null;

    const borrowed_source_flags = regexpBorrowedLatin1SourceFlags(regexp_object);
    if (borrowed_source_flags) |borrowed| {
        const flags = borrowed.flags;
        const is_global = std.mem.indexOfScalar(u8, flags, 'g') != null;
        const is_sticky = std.mem.indexOfScalar(u8, flags, 'y') != null;
        if (is_global or is_sticky) return null;

        if (!regexpSourceUsesZigPropertyFallback(borrowed.source, flags)) {
            if (simpleLatin1LiteralPlusLiteralMatch(borrowed.source, flags, string_value)) |matched| {
                return matched;
            }
            if (nativeFunctionMatcherUnicodeClassAsciiResult(borrowed.source, flags, string_value, 0)) |matched| {
                return matched;
            }
            const full_unicode = regExpFlagsContain(flags, 'u') or regExpFlagsContain(flags, 'v');
            if (full_unicode and parseUnicodeAstralSpecialSource(borrowed.source) != null) {
                return unicodeAstralSpecialMatch(borrowed.source, string_value, 0, false, true) != null;
            }
            if (full_unicode and std.mem.eql(u8, borrowed.source, "^\\S$")) {
                return anchoredSingleNonWhitespaceMatches(string_value, true);
            }
            if (full_unicode and singleLowSurrogateLiteralSource(borrowed.source) != null) {
                return unicodeLowSurrogateLiteralMatch(borrowed.source, string_value, 0, false) != null;
            }
            if (full_unicode) {
                if (simpleUnicodePropertyRunTestFast(borrowed.source, flags, string_value)) |matched| {
                    return matched;
                }
            }
            if (simpleClassEscapeTestFast(borrowed.source, flags, string_value)) |matched| {
                return matched;
            }
            if (simpleAsciiLiteralTestFast(borrowed.source, flags, string_value)) |matched| {
                return matched;
            }
            if (simpleAsciiLiteralClassPlusLiteralTestFast(borrowed.source, flags, string_value)) |matched| {
                return matched;
            }
            if (isSimpleUnicodeLiteralSource(borrowed.source)) {
                return simpleUnicodeLiteralMatch(borrowed.source, string_value, 0, false, flags) != null;
            }
            if (parseSimpleClassSequenceLatin1Source(borrowed.source, flags)) |pattern| {
                return simpleClassSequenceMatchPattern(pattern, string_value, 0, false, flags) != null;
            }
            if (parseSimpleCaptureSequenceSource(borrowed.source, flags)) |pattern| {
                return simpleCaptureSequenceMatchPattern(pattern, string_value, 0, false, flags) != null;
            }
        }
    }

    const cached_bytecode = regexp_object.regexpCompiledBytecode();
    if (cached_bytecode.len != 0) {
        const compiled = quickjs_regexp.Compiled{ .bytecode = @constCast(cached_bytecode) };
        const flag_bits = compiled.flagBits();
        if ((flag_bits & (quickjs_regexp.flag_bits.global | quickjs_regexp.flag_bits.sticky)) != 0) return null;
        return quickjs_regexp.testOnStringFromIndex(compiled, string_value, 0) catch |err| switch (err) {
            error.BytecodeCorrupt, error.Timeout => return null,
            else => return err,
        };
    }

    const borrowed = borrowed_source_flags orelse return null;
    const flags = borrowed.flags;
    const is_global = std.mem.indexOfScalar(u8, flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, flags, 'y') != null;
    if (is_global or is_sticky) return null;
    if (regexpSourceUsesZigPropertyFallback(borrowed.source, flags)) return null;
    if (!bytesAreAscii(borrowed.source)) return null;

    if (regexp_object.regexpCompiledBytecode().len == 0) {
        var compiled = quickjs_regexp.compile(ctx.runtime.memory.allocator, borrowed.source, flags) catch |err| switch (err) {
            error.InvalidPattern, error.Unsupported => return null,
            else => |other| return other,
        };
        defer compiled.deinit(ctx.runtime.memory.allocator);
        try regexp_object.setRegexpCompiledBytecode(ctx.runtime, compiled.bytecode);
    }
    const compiled = quickjs_regexp.Compiled{ .bytecode = @constCast(regexp_object.regexpCompiledBytecode()) };

    return quickjs_regexp.testOnStringFromIndex(compiled, string_value, 0) catch |err| switch (err) {
        error.BytecodeCorrupt, error.Timeout => return null,
        else => return err,
    };
}

pub fn simpleClassEscapeTestFast(source: []const u8, flags: []const u8, string_value: core.JSValue) ?bool {
    if (!isSimpleStringClassEscapeSource(source)) return null;
    if (regExpFlagsContain(flags, 'i')) return null;
    return findStringClassEscapeMatch(string_value, source, 0) != null;
}

pub fn simpleAsciiLiteralTestFast(source: []const u8, flags: []const u8, string_value: core.JSValue) ?bool {
    if (flags.len != 0 or source.len == 0) return null;
    for (source) |byte| {
        if (!isPlainAsciiRegExpLiteral(byte)) return null;
    }
    const input = latin1StringSlice(string_value) orelse return null;
    return std.mem.indexOf(u8, input, source) != null;
}

pub const SimpleAsciiLiteralClassPlusLiteral = struct {
    prefix: []const u8,
    class_source: []const u8,
    suffix: []const u8,
};

pub fn simpleAsciiLiteralClassPlusLiteralTestFast(source: []const u8, flags: []const u8, string_value: core.JSValue) ?bool {
    if (flags.len != 0) return null;
    const pattern = parseSimpleAsciiLiteralClassPlusLiteral(source) orelse return null;
    const input = latin1StringSlice(string_value) orelse return null;
    return simpleAsciiLiteralClassPlusLiteralMatchBytes(pattern, input);
}

pub fn parseSimpleAsciiLiteralClassPlusLiteral(source: []const u8) ?SimpleAsciiLiteralClassPlusLiteral {
    if (source.len < 3) return null;

    var index: usize = 0;
    while (index < source.len and isPlainAsciiRegExpLiteral(source[index])) : (index += 1) {}

    const class_start = index;
    const class_end = blk: {
        if (index + 2 < source.len and source[index] == '\\' and isSimpleClassEscapeByte(source[index + 1]) and source[index + 2] == '+') {
            index += 3;
            break :blk class_start + 2;
        }
        if (index + 3 < source.len and source[index] == '\\' and source[index + 1] == '\\' and isSimpleClassEscapeByte(source[index + 2]) and source[index + 3] == '+') {
            index += 4;
            break :blk class_start + 3;
        }
        return null;
    };

    const suffix_start = index;
    while (index < source.len and isPlainAsciiRegExpLiteral(source[index])) : (index += 1) {}
    if (index != source.len) return null;
    if (class_start == 0 and suffix_start == source.len) return null;

    return .{
        .prefix = source[0..class_start],
        .class_source = source[class_end - 2 .. class_end],
        .suffix = source[suffix_start..],
    };
}

pub fn isPlainAsciiRegExpLiteral(ch: u8) bool {
    if (ch >= '0' and ch <= '9') return true;
    if (ch >= 'A' and ch <= 'Z') return true;
    if (ch >= 'a' and ch <= 'z') return true;
    return switch (ch) {
        '_', ' ' => true,
        else => false,
    };
}

pub fn regexpBorrowedLatin1SourceFlags(object: *core.Object) ?RegExpBorrowedSourceFlags {
    const source_value = object.regexpSource() orelse return null;
    const flags_value = object.regexpFlags() orelse return null;
    const source = latin1StringSlice(source_value) orelse return null;
    const flags = latin1StringSlice(flags_value) orelse return null;
    return .{ .source = source, .flags = flags };
}

pub fn canConstructRegExpFromBorrowedLatin1(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    for (pattern) |byte| {
        switch (byte) {
            '/', '\n', '\r' => return false,
            else => {},
        }
        if (!byteIsAscii(byte)) return false;
    }
    return true;
}

pub fn bytesAreAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!byteIsAscii(byte)) return false;
    }
    return true;
}

pub fn byteIsAscii(byte: u8) bool {
    return byte < 0x80;
}

pub fn regExpLastIndexCanSkipCoercion(object: *core.Object) bool {
    const value = object.regexpLastIndex() orelse return false;
    if (value.isObject() or value.isBigInt() or value.isSymbol()) return false;
    return true;
}

pub fn qjsRegExpCompile(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const regexp_object = property_ops.expectObject(this_value) catch return null;
    if (regexp_object.class_id != core.class.ids.regexp) return null;
    const expected_prototype = regExpPrototypeFromGlobal(ctx.runtime, global) orelse
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    if (regexp_object.getPrototype() != expected_prototype) {
        return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "RegExp object expected"));
    }

    const pattern = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const flags = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();

    const source_value = blk: {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                if (!flags.isUndefined()) return error.TypeError;
                break :blk try regexpInternalStringValue(pattern_object, true);
            }
        }
        if (pattern.isUndefined()) break :blk try value_ops.createStringValue(ctx.runtime, "");
        break :blk try toStringForAnnexB(ctx, output, global, pattern, caller_function, caller_frame);
    };
    defer source_value.free(ctx.runtime);

    const flags_value = blk: {
        if (objectFromValue(pattern)) |pattern_object| {
            if (pattern_object.class_id == core.class.ids.regexp) {
                break :blk try regexpInternalStringValue(pattern_object, false);
            }
        }
        if (flags.isUndefined()) break :blk try value_ops.createStringValue(ctx.runtime, "");
        break :blk try toStringForAnnexB(ctx, output, global, flags, caller_function, caller_frame);
    };
    defer flags_value.free(ctx.runtime);

    var source_bytes = std.ArrayList(u8).empty;
    defer source_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendValueString(ctx.runtime, &source_bytes, source_value);
    var flag_bytes = std.ArrayList(u8).empty;
    defer flag_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendValueString(ctx.runtime, &flag_bytes, flags_value);
    if (!builtins.regexp.validatePatternAndFlags(source_bytes.items, flag_bytes.items)) return error.SyntaxError;

    const next_source = source_value.dup();
    var next_source_owned = true;
    errdefer if (next_source_owned) next_source.free(ctx.runtime);
    const next_flags = flags_value.dup();
    var next_flags_owned = true;
    errdefer if (next_flags_owned) next_flags.free(ctx.runtime);
    const source_slot = regexp_object.regexpSourceSlot();
    const flags_slot = regexp_object.regexpFlagsSlot();
    try ctx.runtime.writeBarrierValueAt(&regexp_object.header, next_source, source_slot);
    try ctx.runtime.writeBarrierValueAt(&regexp_object.header, next_flags, flags_slot);

    const old_source = source_slot.*;
    const old_flags = flags_slot.*;
    source_slot.* = next_source;
    next_source_owned = false;
    flags_slot.* = next_flags;
    next_flags_owned = false;
    if (old_source) |value| value.free(ctx.runtime);
    if (old_flags) |value| value.free(ctx.runtime);
    regexp_object.clearRegexpCompiledBytecode(ctx.runtime);

    try setValuePropertyStrict(ctx, output, global, this_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    return this_value.dup();
}

pub fn qjsRegExpSpeciesConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const regexp_atom = try ctx.runtime.internAtom("RegExp");
    defer ctx.runtime.atoms.free(regexp_atom);
    const default_constructor = global.getProperty(regexp_atom);

    const constructor_value = try getValueProperty(ctx, output, global, rx, core.atom.ids.constructor, caller_function, caller_frame);
    defer constructor_value.free(ctx.runtime);
    if (constructor_value.isUndefined()) return default_constructor;
    if (!constructor_value.isObject()) {
        default_constructor.free(ctx.runtime);
        return error.TypeError;
    }

    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse {
        default_constructor.free(ctx.runtime);
        return error.TypeError;
    };
    const species_value = try getValueProperty(ctx, output, global, constructor_value, species_atom, caller_function, caller_frame);
    defer species_value.free(ctx.runtime);
    if (species_value.isUndefined() or species_value.isNull()) return default_constructor;
    default_constructor.free(ctx.runtime);
    return species_value.dup();
}

pub fn isDefaultRegExpConstructor(rt: *core.JSRuntime, global: *core.Object, value: core.JSValue) bool {
    const regexp_atom = rt.internAtom("RegExp") catch return false;
    defer rt.atoms.free(regexp_atom);
    const default_constructor = global.getProperty(regexp_atom);
    defer default_constructor.free(rt);
    return sameObjectIdentity(default_constructor, value);
}

pub fn regExpFlagsAreFullUnicode(rt: *core.JSRuntime, flags_string: core.JSValue) !bool {
    return try qjsStringValueContainsByte(rt, flags_string, 'u') or
        try qjsStringValueContainsByte(rt, flags_string, 'v');
}

pub fn toLengthIndex(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !usize {
    const length = try toLengthNumber(ctx, output, global, value);
    if (length >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(length);
}

pub fn toLengthNumber(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !f64 {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    if (std.math.isNan(number) or number <= 0) return 0;
    const max_length = 9007199254740991.0;
    if (number >= max_length) return max_length;
    return @floor(number);
}

pub fn qjsRegExpExecSimpleUnicodeLiteral(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const regexp_object = property_ops.expectObject(rx) catch return null;
    if (regexp_object.class_id != core.class.ids.regexp) return null;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    if (!try appendRegExpSource(ctx.runtime, regexp_object, &source)) return null;
    if (!isSimpleUnicodeLiteralSource(source.items)) return null;
    return (try qjsRegExpExecResult(ctx, output, global, rx, regexp_object, string_value, true, caller_function, caller_frame)) orelse null;
}

pub fn regexpInternalFlagsContain(regexp_object: *core.Object, needle: u8) bool {
    if (regexp_object.regexpFlags()) |flags_value| return stringValueContainsUnitByte(flags_value, needle);
    return false;
}

pub fn regexpInternalSimpleQuantifiedClassSource(regexp_object: *core.Object) ?[]const u8 {
    if (regexp_object.regexpSource()) |source_value| return simpleQuantifiedClassSourceFromValue(source_value);
    return null;
}

pub fn simpleQuantifiedClassSourceFromValue(source_value: core.JSValue) ?[]const u8 {
    const sources = [_][]const u8{
        "\\d+",   "\\D+",   "\\s+",   "\\S+",   "\\w+",   "\\W+",
        "\\\\d+", "\\\\D+", "\\\\s+", "\\\\S+", "\\\\w+", "\\\\W+",
    };
    for (sources) |source| {
        if (stringValueUnitsEqualBytes(source_value, source)) return source;
    }
    return null;
}

pub fn setRegExpLastIndexZero(rt: *core.JSRuntime, regexp_object: *core.Object) !void {
    regexp_object.setProperty(rt, core.atom.ids.lastIndex, core.JSValue.int32(0)) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible => return error.TypeError,
        else => return err,
    };
}

pub fn appendNamedCaptureSubstitution(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    named_captures: core.JSValue,
    replacement: []const u16,
    index: *usize,
    out: *std.ArrayList(u16),
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (named_captures.isUndefined()) return false;
    const name_start = index.* + 2;
    const name_end = std.mem.indexOfScalarPos(u16, replacement, name_start, '>') orelse return false;
    var name = std.ArrayList(u8).empty;
    defer name.deinit(ctx.runtime.memory.allocator);
    try appendUtf16UnitsAsUtf8(ctx.runtime, &name, replacement[name_start..name_end]);
    const atom = try ctx.runtime.internAtom(name.items);
    defer ctx.runtime.atoms.free(atom);
    const capture = try getValueProperty(ctx, output, global, named_captures, atom, caller_function, caller_frame);
    defer capture.free(ctx.runtime);
    if (!capture.isUndefined()) {
        const capture_string = try toStringForAnnexB(ctx, output, global, capture, caller_function, caller_frame);
        defer capture_string.free(ctx.runtime);
        try appendStringValueUnits(ctx.runtime, out, capture_string);
    }
    index.* = name_end;
    return true;
}

pub fn appendUtf16UnitsAsUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void {
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const unit = units[index];
        if (isHighSurrogateUnit(unit) and index + 1 < units.len) {
            const next = units[index + 1];
            if (isLowSurrogateUnit(next)) {
                try appendCodepointUtf8(rt, buffer, codePointFromSurrogatePair(unit, next));
                index += 1;
                continue;
            }
        }
        try appendCodepointUtf8(rt, buffer, @intCast(unit));
    }
}

pub fn qjsRegExpExecGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const exec_atom = core.atom.predefinedId("exec", .string) orelse return error.TypeError;
    const exec_method = try getValueProperty(ctx, output, global, rx, exec_atom, caller_function, caller_frame);
    defer exec_method.free(ctx.runtime);
    if (!exec_method.isUndefined() and !exec_method.isNull()) {
        if (isCallableValue(exec_method)) {
            const result = try callValueOrBytecode(ctx, output, global, rx, exec_method, &.{string_value}, caller_function, caller_frame);
            if (!result.isNull() and !result.isObject()) {
                result.free(ctx.runtime);
                return error.TypeError;
            }
            return result;
        }
        const rx_object = objectFromValue(rx) orelse return error.TypeError;
        if (rx_object.class_id != core.class.ids.regexp) return error.TypeError;
    }
    return (try qjsRegExpExecMethod(ctx, output, global, rx, &.{string_value}, caller_function, caller_frame)) orelse error.TypeError;
}

pub fn qjsRegExpAccessor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    getter_value: core.JSValue,
    name: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (std.mem.eql(u8, name, "flags")) {
        if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
        if (!this_value.isObject()) return error.TypeError;
        var flags = std.ArrayList(u8).empty;
        defer flags.deinit(ctx.runtime.memory.allocator);
        const names = [_][]const u8{ "hasIndices", "global", "ignoreCase", "multiline", "dotAll", "unicode", "unicodeSets", "sticky" };
        const chars = [_]u8{ 'd', 'g', 'i', 'm', 's', 'u', 'v', 'y' };
        for (names, chars) |prop_name, flag_char| {
            const atom = try ctx.runtime.internAtom(prop_name);
            defer ctx.runtime.atoms.free(atom);
            const value = try getValueProperty(ctx, output, global, this_value, atom, caller_function, caller_frame);
            defer value.free(ctx.runtime);
            if (valueTruthy(value)) try flags.append(ctx.runtime.memory.allocator, flag_char);
        }
        return (try core.string.String.createUtf8(ctx.runtime, flags.items)).value();
    }
    const object = property_ops.expectObject(this_value) catch return null;
    if (std.mem.eql(u8, name, "source")) {
        if (try isSameRealmRegExpPrototypeGetter(ctx.runtime, global, object, name, getter_value)) return try value_ops.createStringValue(ctx.runtime, "(?:)");
        if (!objectHasRegExpInternalSlots(object)) return throwRegExpAccessorTypeError(ctx, global, getter_value);
        return null;
    }
    if (!std.mem.eql(u8, name, "source")) {
        if (try isSameRealmRegExpPrototypeGetter(ctx.runtime, global, object, name, getter_value)) return core.JSValue.undefinedValue();
        if (!objectHasRegExpInternalSlots(object)) return throwRegExpAccessorTypeError(ctx, global, getter_value);
    }
    return null;
}

pub fn qjsRegExpLegacyAccessor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    method: builtins.regexp.LegacyAccessorMethod,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const owner_global = function_object.functionRealmGlobalPtr() orelse global;
    const regexp_ctor = try regExpConstructorFromGlobal(ctx.runtime, owner_global);
    const receiver = objectFromValue(this_value) orelse return throwTypeErrorMessage(ctx, owner_global, "RegExp legacy accessor receiver mismatch");
    if (receiver != regexp_ctor) return throwTypeErrorMessage(ctx, owner_global, "RegExp legacy accessor receiver mismatch");

    const legacy = try regexp_ctor.ensureRegExpLegacyStatics(ctx.runtime);
    switch (method) {
        .set_input => {
            try materializeRegExpLegacyNoCaptureSlots(ctx.runtime, regexp_ctor, legacy);
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const string_value = try toStringForAnnexB(ctx, output, owner_global, input, caller_function, caller_frame);
            defer string_value.free(ctx.runtime);
            try replaceRegExpLegacySlot(ctx.runtime, regexp_ctor, &legacy.input, string_value);
            return core.JSValue.undefinedValue();
        },
        .get_input => return regExpLegacySlotValue(ctx.runtime, legacy.input),
        .get_last_match => return regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .match) orelse regExpLegacySlotValue(ctx.runtime, legacy.last_match),
        .get_last_paren => return regExpLegacySlotValue(ctx.runtime, legacy.last_paren),
        .get_left_context => return regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .left) orelse regExpLegacySlotValue(ctx.runtime, legacy.left_context),
        .get_right_context => return regExpLegacyNoCaptureSliceValue(ctx.runtime, legacy, .right) orelse regExpLegacySlotValue(ctx.runtime, legacy.right_context),
        else => {
            const capture_index = builtins.regexp.legacyCaptureIndex(method) orelse return error.TypeError;
            return regExpLegacySlotValue(ctx.runtime, legacy.captures[capture_index]);
        },
    }
}

pub fn regExpConstructorFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (global.cachedRealmValue(.regexp_constructor)) |stored| {
        return objectFromValue(stored) orelse error.TypeError;
    }
    const key = try rt.internAtom("RegExp");
    defer rt.atoms.free(key);
    const value = global.getProperty(key);
    defer value.free(rt);
    return objectFromValue(value) orelse error.TypeError;
}

pub fn regExpLegacySlotValue(rt: *core.JSRuntime, slot: ?core.JSValue) !core.JSValue {
    if (slot) |stored| return stored.dup();
    return value_ops.createStringValue(rt, "");
}

pub fn materializeRegExpLegacyNoCaptureSlots(rt: *core.JSRuntime, owner: *core.Object, legacy: anytype) !void {
    if (!legacy.lazy_no_capture_match) return;
    const input = legacy.input orelse {
        legacy.lazy_no_capture_match = false;
        return;
    };

    const matched = try stringSliceValue(rt, input, legacy.lazy_match_index, legacy.lazy_match_len);
    defer matched.free(rt);
    try replaceRegExpLegacySlot(rt, owner, &legacy.last_match, matched);

    if (legacy.lazy_match_index == 0) {
        clearRegExpLegacySlot(rt, &legacy.left_context);
    } else {
        const left = try stringSliceValue(rt, input, 0, legacy.lazy_match_index);
        defer left.free(rt);
        try replaceRegExpLegacySlot(rt, owner, &legacy.left_context, left);
    }

    const right_start = @min(legacy.lazy_match_index + legacy.lazy_match_len, legacy.lazy_input_len);
    if (right_start >= legacy.lazy_input_len) {
        clearRegExpLegacySlot(rt, &legacy.right_context);
    } else {
        const right = try stringSliceValue(rt, input, right_start, legacy.lazy_input_len - right_start);
        defer right.free(rt);
        try replaceRegExpLegacySlot(rt, owner, &legacy.right_context, right);
    }
    legacy.lazy_no_capture_match = false;
}

pub fn clearRegExpLegacySlot(rt: *core.JSRuntime, slot: *?core.JSValue) void {
    const old_value = slot.*;
    slot.* = null;
    if (old_value) |old| old.free(rt);
}

pub fn fastToLengthIndex(value: core.JSValue) ?usize {
    if (value.asInt32()) |int_value| {
        if (int_value <= 0) return 0;
        return @intCast(int_value);
    }
    if (value.asFloat64()) |number| {
        if (std.math.isNan(number) or number <= 0) return 0;
        const max_length = 9007199254740991.0;
        const clamped = if (number >= max_length) max_length else @floor(number);
        if (clamped >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
        return @intFromFloat(clamped);
    }
    return null;
}

pub fn getRegExpLastIndexLength(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    if (objectFromValue(regexp_value) == regexp_object) {
        if (regexp_object.regexpLastIndex()) |stored| {
            if (fastToLengthIndex(stored)) |index| return index;
        }
    }
    const last_index_value = try getValueProperty(ctx, output, global, regexp_value, core.atom.ids.lastIndex, caller_function, caller_frame);
    defer last_index_value.free(ctx.runtime);
    return try toLengthIndex(ctx, output, global, last_index_value);
}

pub fn setRegExpLastIndexStrict(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (objectFromValue(regexp_value) == regexp_object and regexp_object.regexpLastIndex() != null) {
        if (!regexp_object.regexpLastIndexWritable()) return error.TypeError;
        const slot = regexp_object.regexpLastIndexSlot();
        try regexp_object.setOptionalValueSlot(ctx.runtime, slot, value.dup());
        return;
    }
    try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, value, caller_function, caller_frame);
}

pub fn qjsRegExpExecResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    use_last_index: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    const initial_last_index = if (use_last_index)
        try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame)
    else
        0;

    switch (try qjsRegExpExecSimpleCaptureSequenceResult(ctx, output, global, regexp_value, regexp_object, string_value, use_last_index, input_len, initial_last_index, caller_function, caller_frame)) {
        .unsupported => {},
        .value => |value| return value,
    }

    switch (try qjsRegExpExecSimpleClassAlternationResult(ctx, output, global, regexp_value, regexp_object, string_value, use_last_index, input_len, initial_last_index, caller_function, caller_frame)) {
        .unsupported => {},
        .value => |value| return value,
    }

    const cached_bytecode = regexp_object.regexpCompiledBytecode();
    if (cached_bytecode.len != 0) {
        const compiled = quickjs_regexp.Compiled{ .bytecode = @constCast(cached_bytecode) };
        const bits = compiled.flagBits();
        const is_global = (bits & quickjs_regexp.flag_bits.global) != 0;
        const is_sticky = (bits & quickjs_regexp.flag_bits.sticky) != 0;
        const has_indices = (bits & quickjs_regexp.flag_bits.indices) != 0;
        const start_index = if (use_last_index and (is_global or is_sticky)) initial_last_index else 0;
        if (start_index > input_len) {
            if (use_last_index and (is_global or is_sticky)) {
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
            }
            return core.JSValue.nullValue();
        }
        return try qjsRegExpExecCompiledResult(ctx, output, global, regexp_value, regexp_object, string_value, compiled, use_last_index, is_global, is_sticky, has_indices, start_index, caller_function, caller_frame);
    }

    var source = std.ArrayList(u8).empty;
    defer source.deinit(rt.memory.allocator);
    if (!try appendRegExpSource(rt, regexp_object, &source)) return null;

    var flags = std.ArrayList(u8).empty;
    defer flags.deinit(rt.memory.allocator);
    if (!try appendRegExpFlags(rt, regexp_object, &flags)) return null;

    const is_global = std.mem.indexOfScalar(u8, flags.items, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, flags.items, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, flags.items, 'd') != null;
    const start_index = if (use_last_index and (is_global or is_sticky)) initial_last_index else 0;

    if (start_index > input_len) {
        if (use_last_index and (is_global or is_sticky)) {
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return core.JSValue.nullValue();
    }

    if (regexpSourceUsesZigPropertyFallback(source.items, flags.items)) {
        return try qjsRegExpExecPropertyFallback(ctx, output, global, regexp_value, source.items, flags.items, string_value, use_last_index, is_global, is_sticky, has_indices, input_len, start_index, caller_function, caller_frame);
    }
    const full_unicode = regExpFlagsContain(flags.items, 'u') or regExpFlagsContain(flags.items, 'v');
    if (nativeFunctionMatcherUnicodeClassAsciiResult(source.items, flags.items, string_value, start_index)) |matched| {
        if (!matched) return core.JSValue.nullValue();
        const found = RegExpMatch{
            .index = start_index,
            .len = 1,
            .capture_count = 0,
        };
        return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
    }
    if (full_unicode and parseUnicodeAstralSpecialSource(source.items) != null) {
        if (unicodeAstralSpecialMatch(source.items, string_value, start_index, is_sticky, true)) |found| {
            if (use_last_index and (is_global or is_sticky)) {
                const next_index = found.index + found.len;
                const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(next_index))
                else
                    core.JSValue.float64(@floatFromInt(next_index));
                try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
        }
        if (use_last_index and (is_global or is_sticky)) {
            try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return core.JSValue.nullValue();
    }
    if (full_unicode and std.mem.eql(u8, source.items, "^\\S$")) {
        if (start_index == 0 and anchoredSingleNonWhitespaceMatches(string_value, true)) {
            const found = RegExpMatch{ .index = 0, .len = input_len, .capture_count = 0 };
            if (use_last_index and (is_global or is_sticky)) {
                const next_value = if (input_len <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(input_len))
                else
                    core.JSValue.float64(@floatFromInt(input_len));
                try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
        }
        if (use_last_index and (is_global or is_sticky)) {
            try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return core.JSValue.nullValue();
    }
    if (full_unicode and singleLowSurrogateLiteralSource(source.items) != null) {
        if (unicodeLowSurrogateLiteralMatch(source.items, string_value, start_index, is_sticky)) |found| {
            if (use_last_index and (is_global or is_sticky)) {
                const next_index = found.index + found.len;
                const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(next_index))
                else
                    core.JSValue.float64(@floatFromInt(next_index));
                try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
        }
        if (use_last_index and (is_global or is_sticky)) {
            try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return core.JSValue.nullValue();
    }
    if (parseSimpleClassAlternationSource(source.items, flags.items)) |pattern| {
        if (simpleClassAlternationMatchPattern(pattern, string_value, start_index, is_sticky, flags.items)) |found| {
            if (use_last_index and (is_global or is_sticky)) {
                const next_index = found.index + found.len;
                const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(next_index))
                else
                    core.JSValue.float64(@floatFromInt(next_index));
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
        }
        if (use_last_index and (is_global or is_sticky)) {
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return core.JSValue.nullValue();
    }
    if (regexp_object.regexpCompiledBytecode().len == 0) {
        var compiled = quickjs_regexp.compile(rt.memory.allocator, source.items, flags.items) catch |err| switch (err) {
            error.InvalidPattern, error.Unsupported => return try qjsRegExpExecPropertyFallback(ctx, output, global, regexp_value, source.items, flags.items, string_value, use_last_index, is_global, is_sticky, has_indices, input_len, start_index, caller_function, caller_frame),
            else => |other| return other,
        };
        defer compiled.deinit(rt.memory.allocator);
        try regexp_object.setRegexpCompiledBytecode(rt, compiled.bytecode);
    }
    const compiled = quickjs_regexp.Compiled{ .bytecode = @constCast(regexp_object.regexpCompiledBytecode()) };

    return try qjsRegExpExecCompiledResult(ctx, output, global, regexp_value, regexp_object, string_value, compiled, use_last_index, is_global, is_sticky, has_indices, start_index, caller_function, caller_frame);
}

pub fn qjsRegExpExecCompiledResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    compiled: quickjs_regexp.Compiled,
    use_last_index: bool,
    is_global: bool,
    is_sticky: bool,
    has_indices: bool,
    start_index: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const rt = ctx.runtime;
    const status = quickjs_regexp.execOnStringFromIndex(compiled, string_value, start_index) catch |err| switch (err) {
        error.BytecodeCorrupt, error.Timeout => return null,
        else => return err,
    };

    switch (status.result) {
        .match => {
            const match = status.match;
            if (use_last_index and (is_global or is_sticky)) {
                const next_index = match.end;
                const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(next_index))
                else
                    core.JSValue.float64(@floatFromInt(next_index));
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
            }

            var found = RegExpMatch{
                .index = match.start,
                .len = match.end - match.start,
                .capture_count = match.capture_count,
            };
            var capture_index: usize = 0;
            while (capture_index < match.capture_count) : (capture_index += 1) {
                const capture = match.captures[capture_index];
                if (capture.start) |capture_start| {
                    const capture_end = capture.end.?;
                    found.captures[capture_index] = .{
                        .start = capture_start,
                        .len = capture_end - capture_start,
                        .undefined = false,
                        .name = capture.name,
                    };
                } else {
                    found.captures[capture_index] = .{
                        .start = 0,
                        .len = 0,
                        .undefined = true,
                        .name = capture.name,
                    };
                }
            }
            return try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices);
        },
        .no_match, .out_of_range => {
            if (use_last_index and (is_global or is_sticky)) {
                try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
            }
            return core.JSValue.nullValue();
        },
        .not_available => return null,
    }
}

pub const FastRegExpExecResult = union(enum) {
    unsupported,
    value: core.JSValue,
};

pub const RegExpNoCaptureLengthResult = union(enum) {
    unsupported,
    matched: usize,
    no_match,
};

pub const RegExpNoCaptureLengthLoopAllResult = union(enum) {
    unsupported,
    done: usize,
};

pub const RegExpCountLoopAllResult = union(enum) {
    unsupported,
    done: usize,
};

pub fn qjsRegExpLiteralNoCaptureLengthLoopAll(
    ctx: *core.JSContext,
    global: *core.Object,
    source: []const u8,
    flags: []const u8,
    source_atom: core.Atom,
    flags_atom: core.Atom,
    string_value: core.JSValue,
) !RegExpNoCaptureLengthLoopAllResult {
    const is_global = std.mem.indexOfScalar(u8, flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, flags, 'd') != null;
    if (has_indices or (!is_global and !is_sticky)) return .unsupported;

    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    var total_len: usize = 0;
    var last_found: ?RegExpMatch = null;

    if (std.mem.indexOfScalar(u8, source, '|') != null) {
        const parse_source = rt.atoms.name(source_atom) orelse source;
        const parse_flags = if (flags_atom != core.atom.null_atom) rt.atoms.name(flags_atom) orelse flags else flags;
        const pattern = if (rt.cachedRegExpSimpleClassAlternation(source_atom, flags_atom)) |cached|
            cached
        else blk: {
            const parsed = parseSimpleClassAlternationSource(parse_source, parse_flags) orelse return .unsupported;
            rt.setRegExpSimpleClassAlternationCache(source_atom, flags_atom, parsed);
            break :blk parsed;
        };
        if (simpleClassAlternationLengthLoop(pattern, string_value, 0, is_sticky, flags)) |result| {
            total_len += result.total_len;
            last_found = result.last_found;
        } else {
            var search_start: usize = 0;
            while (true) {
                const found = simpleClassAlternationMatchPattern(pattern, string_value, search_start, is_sticky, flags) orelse break;
                if (found.capture_count != 0 or found.len == 0) return .unsupported;
                total_len += found.len;
                search_start = found.index + found.len;
                last_found = found;
            }
        }
    } else {
        const pattern = parseSimpleClassSequenceSource(source, flags) orelse return .unsupported;
        if (simpleClassSequenceSingleUnitLengthLoop(pattern, string_value, 0, is_sticky)) |result| {
            total_len += result.total_len;
            last_found = result.last_found;
        } else {
            var search_start: usize = 0;
            while (true) {
                const found = simpleClassSequenceMatchPattern(pattern, string_value, search_start, is_sticky, flags) orelse break;
                if (found.capture_count != 0 or found.len == 0) return .unsupported;
                total_len += found.len;
                search_start = found.index + found.len;
                last_found = found;
            }
        }
    }

    if (last_found) |found| try updateRegExpLegacyStaticsNoCaptures(rt, global, string_value, found, input_len);
    return .{ .done = total_len };
}

pub const RegExpCaptureLengthSumResult = union(enum) {
    unsupported,
    matched: usize,
};

pub const RegExpCaptureLengthLoopAllResult = union(enum) {
    unsupported,
    done: usize,
};

pub fn qjsRegExpExecNoCaptureLengthForLoop(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpNoCaptureLengthResult {
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    if (std.mem.indexOfScalar(u8, borrowed.source, '|') == null) return .unsupported;
    const pattern = regexpSimpleClassAlternationPattern(ctx.runtime, regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    if (has_indices or (!is_global and !is_sticky)) return .unsupported;

    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    const start_index = try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame);
    if (start_index > input_len) {
        try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
        return .no_match;
    }

    if (simpleClassAlternationMatchPattern(pattern, string_value, start_index, is_sticky, borrowed.flags)) |found| {
        if (found.capture_count != 0 or found.len == 0) return .unsupported;
        const next_index = found.index + found.len;
        const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
            core.JSValue.int32(@intCast(next_index))
        else
            core.JSValue.float64(@floatFromInt(next_index));
        try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
        try updateRegExpLegacyStaticsNoCaptures(rt, global, string_value, found, input_len);
        return .{ .matched = found.len };
    }

    try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    return .no_match;
}

pub fn qjsRegExpExecNoCaptureLengthLoopAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpNoCaptureLengthLoopAllResult {
    if (objectFromValue(regexp_value) != regexp_object or regexp_object.regexpLastIndex() == null or !regexp_object.regexpLastIndexWritable()) return .unsupported;
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    if (has_indices or (!is_global and !is_sticky)) return .unsupported;

    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    var search_start = try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame);
    var total_len: usize = 0;
    var last_found: ?RegExpMatch = null;

    if (search_start <= input_len) {
        if (std.mem.indexOfScalar(u8, borrowed.source, '|') != null) {
            const pattern = regexpSimpleClassAlternationPattern(ctx.runtime, regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
            if (simpleClassAlternationLengthLoop(pattern, string_value, search_start, is_sticky, borrowed.flags)) |result| {
                total_len += result.total_len;
                last_found = result.last_found;
            } else {
                while (true) {
                    const found = simpleClassAlternationMatchPattern(pattern, string_value, search_start, is_sticky, borrowed.flags) orelse break;
                    if (found.capture_count != 0 or found.len == 0) return .unsupported;
                    total_len += found.len;
                    search_start = found.index + found.len;
                    last_found = found;
                }
            }
        } else {
            const pattern = parseSimpleClassSequenceLatin1Source(borrowed.source, borrowed.flags) orelse return .unsupported;
            if (simpleClassSequenceSingleUnitLengthLoop(pattern, string_value, search_start, is_sticky)) |result| {
                total_len += result.total_len;
                last_found = result.last_found;
            } else {
                while (true) {
                    const found = simpleClassSequenceMatchPattern(pattern, string_value, search_start, is_sticky, borrowed.flags) orelse break;
                    if (found.capture_count != 0 or found.len == 0) return .unsupported;
                    total_len += found.len;
                    search_start = found.index + found.len;
                    last_found = found;
                }
            }
        }
    }

    try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    if (last_found) |found| try updateRegExpLegacyStaticsNoCaptures(rt, global, string_value, found, input_len);
    return .{ .done = total_len };
}

pub fn qjsRegExpExecNoCaptureCountLoopAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpCountLoopAllResult {
    if (objectFromValue(regexp_value) != regexp_object or regexp_object.regexpLastIndex() == null or !regexp_object.regexpLastIndexWritable()) return .unsupported;
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    if (has_indices or (!is_global and !is_sticky)) return .unsupported;

    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    var search_start = try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame);
    var count: usize = 0;
    var last_found: ?RegExpMatch = null;

    if (search_start <= input_len) {
        if (std.mem.indexOfScalar(u8, borrowed.source, '|') != null) {
            const pattern = regexpSimpleClassAlternationPattern(ctx.runtime, regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
            if (simpleClassAlternationLengthLoop(pattern, string_value, search_start, is_sticky, borrowed.flags)) |result| {
                count += result.match_count;
                last_found = result.last_found;
            } else {
                while (true) {
                    const found = simpleClassAlternationMatchPattern(pattern, string_value, search_start, is_sticky, borrowed.flags) orelse break;
                    if (found.capture_count != 0 or found.len == 0) return .unsupported;
                    count += 1;
                    search_start = found.index + found.len;
                    last_found = found;
                }
            }
        } else {
            const pattern = parseSimpleClassSequenceLatin1Source(borrowed.source, borrowed.flags) orelse return .unsupported;
            if (simpleClassSequenceSingleUnitLengthLoop(pattern, string_value, search_start, is_sticky)) |result| {
                count += result.match_count;
                last_found = result.last_found;
            } else {
                while (true) {
                    const found = simpleClassSequenceMatchPattern(pattern, string_value, search_start, is_sticky, borrowed.flags) orelse break;
                    if (found.capture_count != 0 or found.len == 0) return .unsupported;
                    count += 1;
                    search_start = found.index + found.len;
                    last_found = found;
                }
            }
        }
    }

    try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    if (last_found) |found| try updateRegExpLegacyStaticsNoCaptures(rt, global, string_value, found, input_len);
    return .{ .done = count };
}

pub fn qjsRegExpExecCaptureLengthSumLoopAll(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    capture_indexes: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpCaptureLengthLoopAllResult {
    if (objectFromValue(regexp_value) != regexp_object or regexp_object.regexpLastIndex() == null or !regexp_object.regexpLastIndexWritable()) return .unsupported;
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    if (has_indices or (!is_global and !is_sticky)) return .unsupported;
    const pattern = regexpSimpleCaptureSequencePattern(regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;

    const rt = ctx.runtime;
    const input_len = try stringLengthIndex(rt, string_value);
    var search_start = try getRegExpLastIndexLength(ctx, output, global, regexp_value, regexp_object, caller_function, caller_frame);
    var total_sum: usize = 0;
    var last_found: ?RegExpMatch = null;

    if (search_start <= input_len) {
        if (simpleCaptureSequenceLengthSumLoop(pattern, string_value, search_start, is_sticky, borrowed.flags, capture_indexes)) |result| {
            total_sum = result.total_sum;
            last_found = result.last_found;
        } else {
            while (true) {
                const found = simpleCaptureSequenceMatchPattern(pattern, string_value, search_start, is_sticky, borrowed.flags) orelse break;
                if (found.len == 0) return .unsupported;
                const sum = captureLengthSum(found, capture_indexes) orelse return .unsupported;
                total_sum = std.math.add(usize, total_sum, sum) catch return .unsupported;
                search_start = found.index + found.len;
                last_found = found;
            }
        }
    }

    try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    if (last_found) |found| try updateRegExpLegacyStaticsForMatch(rt, global, string_value, found);
    return .{ .done = total_sum };
}

pub fn qjsRegExpExecCaptureLengthSumForLoop(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    capture_indexes: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !RegExpCaptureLengthSumResult {
    _ = output;
    _ = regexp_value;
    _ = caller_function;
    _ = caller_frame;
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    if (std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null or
        std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null or
        std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null)
    {
        return .unsupported;
    }
    const pattern = regexpSimpleCaptureSequencePattern(regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
    const found = simpleCaptureSequenceMatchPattern(pattern, string_value, 0, false, borrowed.flags) orelse return .unsupported;

    const sum = captureLengthSum(found, capture_indexes) orelse return .unsupported;

    try updateRegExpLegacyStaticsForMatch(ctx.runtime, global, string_value, found);
    return .{ .matched = sum };
}

pub fn captureLengthSum(found: RegExpMatch, capture_indexes: []const u8) ?usize {
    var sum: usize = 0;
    for (capture_indexes) |capture_index| {
        const len = if (capture_index == 0) found.len else blk: {
            const zero_based = @as(usize, capture_index) - 1;
            if (zero_based >= found.capture_count) return null;
            const capture = found.captures[zero_based];
            if (capture.undefined) return null;
            break :blk capture.len;
        };
        sum = std.math.add(usize, sum, len) catch return null;
    }
    return sum;
}

pub fn qjsRegExpExecSimpleCaptureSequenceResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    use_last_index: bool,
    input_len: usize,
    initial_last_index: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !FastRegExpExecResult {
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    if (std.mem.indexOfScalar(u8, borrowed.source, '(') == null) return .unsupported;
    const pattern = regexpSimpleCaptureSequencePattern(regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
    const rt = ctx.runtime;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    const start_index = if (use_last_index and (is_global or is_sticky)) initial_last_index else 0;
    if (start_index > input_len) {
        if (use_last_index and (is_global or is_sticky)) {
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return .{ .value = core.JSValue.nullValue() };
    }

    if (simpleCaptureSequenceMatchPattern(pattern, string_value, start_index, is_sticky, borrowed.flags)) |found| {
        if (use_last_index and (is_global or is_sticky)) {
            const next_index = found.index + found.len;
            const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                core.JSValue.int32(@intCast(next_index))
            else
                core.JSValue.float64(@floatFromInt(next_index));
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
        }
        return .{ .value = try createRegExpMatchArrayFromValue(rt, global, string_value, found, has_indices) };
    }

    if (use_last_index and (is_global or is_sticky)) {
        try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    }
    return .{ .value = core.JSValue.nullValue() };
}

pub fn regexpSimpleCaptureSequencePattern(regexp_object: *core.Object, source: []const u8, flags: []const u8) ?SimpleCaptureSequencePattern {
    if (regexp_object.regexpSimpleCaptureSequenceCache()) |pattern| return pattern;
    const pattern = parseSimpleCaptureSequenceSource(source, flags) orelse return null;
    regexp_object.setRegexpSimpleCaptureSequenceCache(pattern);
    return pattern;
}

pub fn qjsRegExpExecSimpleClassAlternationResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    regexp_object: *core.Object,
    string_value: core.JSValue,
    use_last_index: bool,
    input_len: usize,
    initial_last_index: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !FastRegExpExecResult {
    const borrowed = regexpBorrowedLatin1SourceFlags(regexp_object) orelse return .unsupported;
    if (std.mem.indexOfScalar(u8, borrowed.source, '|') == null) return .unsupported;
    const pattern = regexpSimpleClassAlternationPattern(ctx.runtime, regexp_object, borrowed.source, borrowed.flags) orelse return .unsupported;
    const rt = ctx.runtime;
    const is_global = std.mem.indexOfScalar(u8, borrowed.flags, 'g') != null;
    const is_sticky = std.mem.indexOfScalar(u8, borrowed.flags, 'y') != null;
    const has_indices = std.mem.indexOfScalar(u8, borrowed.flags, 'd') != null;
    const start_index = if (use_last_index and (is_global or is_sticky)) initial_last_index else 0;
    if (start_index > input_len) {
        if (use_last_index and (is_global or is_sticky)) {
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
        }
        return .{ .value = core.JSValue.nullValue() };
    }

    if (simpleClassAlternationMatchPattern(pattern, string_value, start_index, is_sticky, borrowed.flags)) |found| {
        if (use_last_index and (is_global or is_sticky)) {
            const next_index = found.index + found.len;
            const next_value = if (next_index <= @as(usize, @intCast(std.math.maxInt(i32))))
                core.JSValue.int32(@intCast(next_index))
            else
                core.JSValue.float64(@floatFromInt(next_index));
            try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, next_value, caller_function, caller_frame);
        }
        return .{ .value = try createRegExpMatchArrayNoCapturesFromValue(rt, global, string_value, found, input_len, has_indices) };
    }

    if (use_last_index and (is_global or is_sticky)) {
        try setRegExpLastIndexStrict(ctx, output, global, regexp_value, regexp_object, core.JSValue.int32(0), caller_function, caller_frame);
    }
    return .{ .value = core.JSValue.nullValue() };
}

pub fn regexpSimpleClassAlternationPattern(rt: *core.JSRuntime, regexp_object: *core.Object, source: []const u8, flags: []const u8) ?SimpleClassAlternationPattern {
    if (regexp_object.regexpSimpleClassAlternationCache()) |pattern| return pattern;
    const source_atom = if (regexp_object.regexpSource()) |value| stringAtomId(value) else null;
    const flags_atom = if (regexp_object.regexpFlags()) |value| stringAtomId(value) else null;
    if (source_atom != null and flags_atom != null) {
        if (rt.cachedRegExpSimpleClassAlternation(source_atom.?, flags_atom.?)) |pattern| {
            regexp_object.setRegexpSimpleClassAlternationCache(pattern);
            return pattern;
        }
    }

    const parse_source = if (source_atom) |atom_id| rt.atoms.name(atom_id) orelse source else source;
    const parse_flags = if (flags_atom) |atom_id| rt.atoms.name(atom_id) orelse flags else flags;
    const pattern = parseSimpleClassAlternationSource(parse_source, parse_flags) orelse return null;
    regexp_object.setRegexpSimpleClassAlternationCache(pattern);
    if (source_atom != null and flags_atom != null) rt.setRegExpSimpleClassAlternationCache(source_atom.?, flags_atom.?, pattern);
    return pattern;
}

pub fn qjsRegExpExecAnchoredRgiEmojiFallback(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    string_value: core.JSValue,
    use_last_index: bool,
    is_global: bool,
    is_sticky: bool,
    has_indices: bool,
    input_len: usize,
    start_index: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const update_last_index = use_last_index and (is_global or is_sticky);
    if (start_index != 0 or !anchoredRgiEmojiMatches(string_value)) {
        if (update_last_index) try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
        return core.JSValue.nullValue();
    }

    if (update_last_index) {
        const next_value = if (input_len <= @as(usize, @intCast(std.math.maxInt(i32))))
            core.JSValue.int32(@intCast(input_len))
        else
            core.JSValue.float64(@floatFromInt(input_len));
        try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
    }

    return try createRegExpMatchArrayFromValue(ctx.runtime, global, string_value, .{
        .index = 0,
        .len = input_len,
        .capture_count = 0,
    }, has_indices);
}

pub fn regExpFlagsContain(flags: []const u8, needle: u8) bool {
    return std.mem.indexOfScalar(u8, flags, needle) != null;
}

pub fn isAnchoredRgiEmojiSource(source: []const u8) bool {
    const name = anchoredStringPropertyName(source) orelse return false;
    return std.mem.eql(u8, name, "RGI_Emoji");
}

pub fn appendRepeatedFillUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), fill: []const u16, length: usize) !void {
    var index: usize = 0;
    while (index < length) : (index += 1) {
        try out.append(rt.memory.allocator, fill[index % fill.len]);
    }
}

pub const NormalizedUtf32 = struct {
    allocator: std.mem.Allocator,
    slice: []u32,

    pub fn deinit(self: NormalizedUtf32) void {
        self.allocator.free(self.slice);
    }
};

pub fn normalizedUtf32(rt: *core.JSRuntime, value: core.JSValue, form: unicode_lib.NormalizationForm) !NormalizedUtf32 {
    var input = std.ArrayList(u32).empty;
    defer input.deinit(rt.memory.allocator);
    try appendUtf32FromStringValue(rt, &input, value);
    return .{
        .allocator = rt.memory.allocator,
        .slice = try unicode_lib.normalizeAlloc(rt.memory.allocator, input.items, form),
    };
}

pub fn qjsDateToPrimitiveNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return date_vm.qjsDateToPrimitiveCall(ctx, output, global, this_value, args, caller_function, caller_frame);
}

pub fn toNumberLikeArgument(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    return value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
}

pub fn qjsGlobalParseInt(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = if (input.isString())
        input
    else
        try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    defer if (!input.isString()) string_value.free(ctx.runtime);

    const radix_value: ?core.JSValue = if (args.len >= 2) blk: {
        const radix_input = args[1];
        if (!radix_input.isObject() and !radix_input.isSymbol() and !radix_input.isBigInt()) break :blk radix_input;
        const primitive = try toPrimitiveForNumber(ctx, output, global, radix_input);
        defer primitive.free(ctx.runtime);
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        defer number_value.free(ctx.runtime);
        break :blk value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
    } else null;
    return value_ops.numberToValue(try builtins.number.parseIntValue(ctx.runtime, string_value, radix_value));
}

pub fn qjsGlobalParseFloat(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = if (input.isString())
        input
    else
        try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    defer if (!input.isString()) string_value.free(ctx.runtime);
    return value_ops.numberToValue(try builtins.number.parseFloatValue(ctx.runtime, string_value));
}

pub fn qjsMathCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const number = switch (id) {
        1 => @abs(try mathArg(ctx, output, global, args, 0)),
        2 => @floor(try mathArg(ctx, output, global, args, 0)),
        3 => @ceil(try mathArg(ctx, output, global, args, 0)),
        4 => qjsMathRound(try mathArg(ctx, output, global, args, 0)),
        5 => @sqrt(try mathArg(ctx, output, global, args, 0)),
        6 => qjsMathPow(try mathArg(ctx, output, global, args, 0), try mathArg(ctx, output, global, args, 1)),
        7 => try qjsMathMinMax(ctx, output, global, args, false),
        8 => try qjsMathMinMax(ctx, output, global, args, true),
        9 => 0.5,
        10 => builtins.math.exp(try mathArg(ctx, output, global, args, 0)),
        11 => @sin(try mathArg(ctx, output, global, args, 0)),
        12 => @cos(try mathArg(ctx, output, global, args, 0)),
        13 => @tan(try mathArg(ctx, output, global, args, 0)),
        14 => std.math.acos(try mathArg(ctx, output, global, args, 0)),
        15 => std.math.asin(try mathArg(ctx, output, global, args, 0)),
        16 => std.math.atan(try mathArg(ctx, output, global, args, 0)),
        17 => std.math.atan2(try mathArg(ctx, output, global, args, 0), try mathArg(ctx, output, global, args, 1)),
        18 => std.math.acosh(try mathArg(ctx, output, global, args, 0)),
        19 => std.math.asinh(try mathArg(ctx, output, global, args, 0)),
        20 => std.math.atanh(try mathArg(ctx, output, global, args, 0)),
        21 => @log(try mathArg(ctx, output, global, args, 0)),
        22 => blk: {
            const a = try mathArg(ctx, output, global, args, 0);
            break :blk if (std.math.isNan(a) or a == 0 or !std.math.isFinite(a)) a else if (a < 0) -@floor(@abs(a)) else @floor(a);
        },
        23 => std.math.cbrt(try mathArg(ctx, output, global, args, 0)),
        24 => @as(f64, @floatFromInt(@clz(toUint32Number(try mathArg(ctx, output, global, args, 0))))),
        25 => std.math.cosh(try mathArg(ctx, output, global, args, 0)),
        26 => std.math.expm1(try mathArg(ctx, output, global, args, 0)),
        27 => @as(f64, @floatCast(@as(f16, @floatCast(try mathArg(ctx, output, global, args, 0))))),
        28 => @as(f64, @floatCast(@as(f32, @floatCast(try mathArg(ctx, output, global, args, 0))))),
        29 => try qjsMathHypot(ctx, output, global, args),
        30 => @as(f64, @floatFromInt(qjsMathImul(try mathArg(ctx, output, global, args, 0), try mathArg(ctx, output, global, args, 1)))),
        31 => std.math.log1p(try mathArg(ctx, output, global, args, 0)),
        32 => builtins.math.log2(try mathArg(ctx, output, global, args, 0)),
        33 => @log10(try mathArg(ctx, output, global, args, 0)),
        34 => qjsMathSign(try mathArg(ctx, output, global, args, 0)),
        35 => std.math.sinh(try mathArg(ctx, output, global, args, 0)),
        36 => std.math.tanh(try mathArg(ctx, output, global, args, 0)),
        else => return error.TypeError,
    };
    return value_ops.numberToValue(number);
}

pub fn mathArg(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, index: usize) !f64 {
    if (index >= args.len) return std.math.nan(f64);
    return toMathNumber(ctx, output, global, args[index]);
}

pub fn toMathNumber(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !f64 {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    return value_ops.numberValue(number_value) orelse std.math.nan(f64);
}

pub fn qjsMathMinMax(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, is_max: bool) !f64 {
    if (args.len == 2) {
        const a_val = args[0];
        const b_val = args[1];
        if (a_val.tag == core.Tag.int and b_val.tag == core.Tag.int) {
            const a_i32 = a_val.asInt32().?;
            const b_i32 = b_val.asInt32().?;
            if (a_i32 == 0 and b_i32 == 0) return 0.0;
            return @floatFromInt(if (is_max) (if (a_i32 > b_i32) a_i32 else b_i32) else (if (a_i32 < b_i32) a_i32 else b_i32));
        }
        if (a_val.isNumber() and b_val.isNumber()) {
            const a = qjsPrimitiveMathNumber(a_val).?;
            const b = qjsPrimitiveMathNumber(b_val).?;
            if (std.math.isNan(a)) return a;
            if (std.math.isNan(b)) return b;
            return if (is_max) qjsFmax(a, b) else qjsFmin(a, b);
        }
    }
    if (args.len == 0) return if (is_max) -std.math.inf(f64) else std.math.inf(f64);
    if (qjsMathMinMaxPrimitiveFast(args, is_max)) |fast| return fast;
    var result = try toMathNumber(ctx, output, global, args[0]);
    for (args[1..]) |arg| {
        const number = try toMathNumber(ctx, output, global, arg);
        if (!std.math.isNan(result)) {
            result = if (std.math.isNan(number))
                number
            else if (is_max)
                qjsFmax(result, number)
            else
                qjsFmin(result, number);
        }
    }
    return result;
}

pub fn qjsMathMinMaxPrimitiveFast(args: []const core.JSValue, is_max: bool) ?f64 {
    var result = if (is_max) -std.math.inf(f64) else std.math.inf(f64);
    for (args) |arg| {
        const number = qjsPrimitiveMathNumber(arg) orelse return null;
        if (!std.math.isNan(result)) {
            result = if (std.math.isNan(number))
                number
            else if (is_max)
                qjsFmax(result, number)
            else
                qjsFmin(result, number);
        }
    }
    return result;
}

pub fn qjsPrimitiveMathNumber(value: core.JSValue) ?f64 {
    if (value.tag == core.Tag.int) return @floatFromInt(value.asInt32().?);
    if (value.tag == core.Tag.float64) return value.asFloat64().?;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    return null;
}

pub fn qjsFmin(a: f64, b: f64) f64 {
    if (a == 0 and b == 0) return @bitCast(@as(u64, @bitCast(a)) | @as(u64, @bitCast(b)));
    return if (a < b) a else b;
}

pub fn qjsFmax(a: f64, b: f64) f64 {
    if (a == 0 and b == 0) return @bitCast(@as(u64, @bitCast(a)) & @as(u64, @bitCast(b)));
    return if (a < b) b else a;
}

pub fn qjsMathPow(a: f64, b: f64) f64 {
    if (!std.math.isFinite(b) and @abs(a) == 1) return std.math.nan(f64);
    return std.math.pow(f64, a, b);
}

pub fn qjsMathRound(a: f64) f64 {
    var bits: u64 = @bitCast(a);
    const exponent = (bits >> 52) & 0x7ff;
    if (exponent < 1023) {
        if (exponent == 1022 and bits != 0xbfe0000000000000) {
            bits = (bits & (@as(u64, 1) << 63)) | (@as(u64, 1023) << 52);
        } else {
            bits &= @as(u64, 1) << 63;
        }
    } else if (exponent < 1075) {
        const sign = bits >> 63;
        const one = @as(u64, 1) << @intCast(52 - (exponent - 1023));
        const frac_mask = one - 1;
        bits +%= (one >> 1) -% sign;
        bits &= ~frac_mask;
    }
    return @bitCast(bits);
}

pub fn qjsMathHypot(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue) !f64 {
    if (args.len == 0) return 0;
    var result = try toMathNumber(ctx, output, global, args[0]);
    if (args.len == 1) return @abs(result);
    for (args[1..]) |arg| {
        const number = try toMathNumber(ctx, output, global, arg);
        result = std.math.hypot(result, number);
    }
    return result;
}

pub fn qjsMathImul(lhs: f64, rhs: f64) i32 {
    const product = toUint32Number(lhs) *% toUint32Number(rhs);
    return @bitCast(product);
}

pub fn qjsMathSign(value: f64) f64 {
    if (std.math.isNan(value) or value == 0) return value;
    return if (value < 0) -1 else 1;
}

pub fn appendAsciiUnits(rt: *core.JSRuntime, out: *std.ArrayList(u16), bytes: []const u8) !void {
    for (bytes) |byte| try out.append(rt.memory.allocator, byte);
}

pub fn isRegExpValue(value: core.JSValue) bool {
    const object = property_ops.expectObject(value) catch return false;
    return object.class_id == core.class.ids.regexp;
}

pub fn isRegExpObservable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (!value.isObject()) return false;
    const match_atom = core.atom.predefinedId("Symbol.match", .symbol) orelse return isRegExpValue(value);
    const matcher = try getValueProperty(ctx, output, global, value, match_atom, caller_function, caller_frame);
    defer matcher.free(ctx.runtime);
    if (!matcher.isUndefined()) return valueTruthy(matcher);
    return isRegExpValue(value);
}

pub fn appendRegExpSource(rt: *core.JSRuntime, object: *core.Object, out: *std.ArrayList(u8)) !bool {
    if (object.regexpSource()) |source_value| {
        try value_ops.appendValueString(rt, out, source_value);
        return true;
    }
    return false;
}

pub fn appendRegExpFlags(rt: *core.JSRuntime, object: *core.Object, out: *std.ArrayList(u8)) !bool {
    if (object.regexpFlags()) |flags_value| {
        try value_ops.appendRawString(rt, out, flags_value);
        return true;
    }
    return false;
}

pub fn appendRegExpInputUnits(rt: *core.JSRuntime, out: *std.ArrayList(u8), value: core.JSValue) !void {
    const header = value.refHeader() orelse return value_ops.appendRawString(rt, out, value);
    if (!value.isString()) return value_ops.appendRawString(rt, out, value);
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try out.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            for (units) |unit| {
                const tag: u8 = if (unit <= 0xff) @intCast(unit) else @intCast(unit >> 8);
                try out.append(rt.memory.allocator, tag);
            }
        },
    }
}

pub fn singleUnicodeEscapeUnit(source: []const u8) ?u16 {
    if (source.len != 6 or source[0] != '\\' or source[1] != 'u') return null;
    var value: u16 = 0;
    var index: usize = 2;
    while (index < source.len) : (index += 1) {
        const digit = std.fmt.charToDigit(source[index], 16) catch return null;
        value = value * 16 + @as(u16, @intCast(digit));
    }
    return value;
}

pub fn singleLowSurrogateLiteralSource(source: []const u8) ?u16 {
    const unit = singleUnicodeEscapeUnit(source) orelse return null;
    return if (isLowSurrogateUnit(unit)) unit else null;
}

pub fn lowSurrogateLiteralAt(unit: u16, string_value: core.string.String, pos: usize) ?RegExpMatch {
    if (pos >= string_value.len() or string_value.codeUnitAt(pos) != unit) return null;
    return .{ .index = pos, .len = 1 };
}

pub fn singleUnicodeClassEscapeUnit(source: []const u8) ?u16 {
    if (source.len != 8 or source[0] != '[' or source[1] != '\\' or source[2] != 'u' or source[7] != ']') return null;
    var value: u16 = 0;
    var index: usize = 3;
    while (index < 7) : (index += 1) {
        const digit = std.fmt.charToDigit(source[index], 16) catch return null;
        value = value * 16 + @as(u16, @intCast(digit));
    }
    return value;
}

pub fn findCharacterClassEnd(source: []const u8, class_start: usize) ?usize {
    if (class_start >= source.len or source[class_start] != '[') return null;
    var index = class_start + 1;
    var at_start = true;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\') {
            if (index + 1 >= source.len) return null;
            index += 1;
            at_start = false;
            continue;
        }
        if (source[index] == ']' and !at_start) return index;
        at_start = false;
    }
    return null;
}

pub fn standaloneCharacterClassSource(source: []const u8) ?[]const u8 {
    if (source.len < 2 or source[0] != '[') return null;
    const class_end = findCharacterClassEnd(source, 0) orelse return null;
    if (class_end + 1 != source.len) return null;
    return source;
}

pub fn leadingAlternationCharacterClassSource(source: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, source, "(?:[")) return null;
    const class_end = findCharacterClassEnd(source, 3) orelse return null;
    if (class_end + 1 >= source.len or source[class_end + 1] != '|') return null;
    return source[3 .. class_end + 1];
}

pub const SimpleUnicodeLiteralPattern = struct {
    units: [64]u16 = undefined,
    len: usize = 0,
    anchor_start: bool = false,
    anchor_end: bool = false,
};

pub const SimpleClassSequenceAtom = core.object.RegExpSimpleClassSequenceAtom;

pub const SimpleCaptureSequenceAtom = core.object.RegExpSimpleCaptureSequenceAtom;

pub const SimpleClassPredicate = core.object.RegExpSimpleClassPredicate;

pub const SimpleCaptureSequencePattern = core.object.RegExpSimpleCaptureSequencePattern;

pub const SimpleClassSequencePattern = core.object.RegExpSimpleClassSequencePattern;
pub const SimpleClassAlternationPattern = core.object.RegExpSimpleClassAlternationPattern;

pub fn isSimpleUnicodeLiteralSource(source: []const u8) bool {
    return parseSimpleUnicodeLiteralSource(source) != null;
}

pub fn isSimpleClassSequenceSource(source: []const u8, flags: []const u8) bool {
    return parseSimpleClassSequenceSource(source, flags) != null;
}

pub fn parseSimpleCaptureSequenceSource(source: []const u8, flags: []const u8) ?SimpleCaptureSequencePattern {
    if (source.len == 0 or hasFlag(flags, 'i') or hasFlag(flags, 'u') or hasFlag(flags, 'v') or hasFlag(flags, 's')) return null;
    var pattern = SimpleCaptureSequencePattern{};
    var index: usize = 0;
    if (source[index] == '^') {
        pattern.anchor_start = true;
        index += 1;
    }
    const end_limit = if (source.len > index and source[source.len - 1] == '$') blk: {
        pattern.anchor_end = true;
        break :blk source.len - 1;
    } else source.len;
    while (index < end_limit) {
        if (pattern.len >= pattern.atoms.len) return null;
        var capture_index: ?usize = null;
        var atom: SimpleCaptureSequenceAtom = undefined;
        if (source[index] == '(') {
            if (index + 1 >= end_limit or source[index + 1] == '?') return null;
            index += 1;
            pattern.capture_count += 1;
            if (pattern.capture_count > 255) return null;
            capture_index = pattern.capture_count;
            atom = parseSimpleCaptureSequenceAtom(source, &index, end_limit, capture_index) orelse return null;
            if (index >= end_limit or source[index] != ')') return null;
            index += 1;
            if (index < end_limit) {
                switch (source[index]) {
                    '*', '+', '?', '{' => return null,
                    else => {},
                }
            }
        } else {
            atom = parseSimpleCaptureSequenceAtom(source, &index, end_limit, null) orelse return null;
        }
        pattern.atoms[pattern.len] = atom;
        pattern.len += 1;
    }
    if (pattern.len == 0 or pattern.capture_count == 0) return null;
    return pattern;
}

pub fn parseSimpleCaptureSequenceAtom(source: []const u8, index: *usize, end_limit: usize, capture_index: ?usize) ?SimpleCaptureSequenceAtom {
    var atom = SimpleCaptureSequenceAtom{ .capture_index = capture_index };
    if (index.* >= end_limit) return null;
    if (source[index.*] == '[') {
        const class_end = findCharacterClassEnd(source, index.*) orelse return null;
        if (class_end >= end_limit) return null;
        atom.kind = .class;
        atom.class_source = source[index.* .. class_end + 1];
        atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
        index.* = class_end + 1;
    } else if (source[index.*] == '\\') {
        if (index.* + 1 >= end_limit) return null;
        if (index.* + 2 < end_limit and source[index.* + 1] == '\\' and isSimpleClassEscapeByte(source[index.* + 2])) {
            atom.kind = .class;
            atom.class_source = source[index.* + 1 .. index.* + 3];
            atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
            index.* += 3;
            return parseSimpleCaptureSequenceAtomQuantifier(source, index, end_limit, capture_index, atom);
        }
        switch (source[index.* + 1]) {
            'd', 'D', 's', 'S', 'w', 'W' => {
                atom.kind = .class;
                atom.class_source = source[index.* .. index.* + 2];
                atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
                index.* += 2;
            },
            else => {
                atom.kind = .literal;
                atom.literal = parseSimpleClassSequenceEscapedLiteral(source, index, end_limit) orelse return null;
            },
        }
    } else {
        atom.kind = .literal;
        atom.literal = parseSimpleClassSequenceLiteral(source, index, end_limit) orelse return null;
    }

    return parseSimpleCaptureSequenceAtomQuantifier(source, index, end_limit, capture_index, atom);
}

pub fn parseSimpleCaptureSequenceAtomQuantifier(source: []const u8, index: *usize, end_limit: usize, capture_index: ?usize, initial_atom: SimpleCaptureSequenceAtom) ?SimpleCaptureSequenceAtom {
    var atom = initial_atom;
    if (index.* < end_limit) {
        switch (source[index.*]) {
            '*' => {
                if (capture_index != null) return null;
                atom.min_repeat = 0;
                atom.max_repeat = std.math.maxInt(usize);
                index.* += 1;
            },
            '+' => {
                atom.max_repeat = std.math.maxInt(usize);
                index.* += 1;
            },
            '?' => {
                if (capture_index != null) return null;
                atom.min_repeat = 0;
                atom.max_repeat = 1;
                index.* += 1;
            },
            '{', '|', ')' => {},
            else => {},
        }
    }
    return atom;
}

pub const SimpleClassSequenceLengthLoopResult = struct {
    total_len: usize,
    match_count: usize,
    last_found: ?RegExpMatch,
};

pub const SimpleClassAlternationLengthLoopResult = struct {
    total_len: usize,
    match_count: usize,
    last_found: ?RegExpMatch,
};

pub fn simpleClassSequenceSingleUnitLengthLoop(pattern: SimpleClassSequencePattern, value: core.JSValue, start: usize, sticky: bool) ?SimpleClassSequenceLengthLoopResult {
    if (pattern.len != 1 or pattern.anchor_start or pattern.anchor_end) return null;
    const atom = pattern.atoms[0];
    if (atom.min_repeat != 1 or atom.max_repeat != 1) return null;
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleClassSequenceSingleUnitLengthLoopLatin1(atom, bytes, start, sticky),
        .utf16 => |units| simpleClassSequenceSingleUnitLengthLoopUtf16(atom, units, start, sticky),
    };
}

pub fn simpleClassAlternationSingleAtomRunLengthLoop(pattern: SimpleClassAlternationPattern, value: core.JSValue, start: usize, sticky: bool) ?SimpleClassAlternationLengthLoopResult {
    if (pattern.len < 2) return null;
    for (pattern.alternatives[0..pattern.len]) |alternative| {
        if (alternative.len != 1 or alternative.anchor_start or alternative.anchor_end) return null;
        const atom = alternative.atoms[0];
        if (atom.min_repeat != 1) return null;
        if (atom.max_repeat != 1 and atom.max_repeat != std.math.maxInt(usize)) return null;
    }

    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleClassAlternationSingleAtomRunLengthLoopLatin1(pattern, bytes, start, sticky),
        .utf16 => |units| simpleClassAlternationSingleAtomRunLengthLoopUtf16(pattern, units, start, sticky),
    };
}

pub fn simpleClassAlternationLengthLoop(pattern: SimpleClassAlternationPattern, value: core.JSValue, start: usize, sticky: bool, flags: []const u8) ?SimpleClassAlternationLengthLoopResult {
    if (simpleClassAlternationSingleAtomRunLengthLoop(pattern, value, start, sticky)) |result| return result;
    if (pattern.len < 2) return null;
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleClassAlternationLengthLoopLatin1(pattern, bytes, start, sticky, flags),
        .utf16 => |units| simpleClassAlternationLengthLoopUtf16(pattern, units, start, sticky, flags),
    };
}

pub const SimpleCaptureLengthSumLoopResult = struct {
    total_sum: usize,
    last_found: ?RegExpMatch,
};

pub fn simpleCaptureSequenceLengthSumLoop(
    pattern: SimpleCaptureSequencePattern,
    value: core.JSValue,
    start: usize,
    sticky: bool,
    flags: []const u8,
    capture_indexes: []const u8,
) ?SimpleCaptureLengthSumLoopResult {
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    return switch (string_value.resolveData()) {
        .latin1 => |bytes| simpleCaptureSequenceLengthSumLoopLatin1(pattern, bytes, start, sticky, flags, capture_indexes),
        .utf16 => |units| simpleCaptureSequenceLengthSumLoopUtf16(pattern, units, start, sticky, flags, capture_indexes),
    };
}

pub fn simpleClassAlternationSingleAtomRunLengthLoopLatin1(pattern: SimpleClassAlternationPattern, bytes: []const u8, start: usize, sticky: bool) SimpleClassAlternationLengthLoopResult {
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index < bytes.len) {
        var matched_atom: ?SimpleClassSequenceAtom = null;
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            const atom = alternative.atoms[0];
            if (simpleClassSequenceAtomMatches(atom, bytes[index])) {
                matched_atom = atom;
                break;
            }
        }

        const atom = matched_atom orelse {
            if (sticky) break;
            index += 1;
            continue;
        };
        const match_start = index;
        index += 1;
        if (atom.max_repeat == std.math.maxInt(usize)) {
            while (index < bytes.len and simpleClassSequenceAtomMatches(atom, bytes[index])) : (index += 1) {}
        }
        const len = index - match_start;
        total_len += len;
        match_count += 1;
        last_found = .{ .index = match_start, .len = len };
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationSingleAtomRunLengthLoopUtf16(pattern: SimpleClassAlternationPattern, units: []const u16, start: usize, sticky: bool) SimpleClassAlternationLengthLoopResult {
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > units.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index < units.len) {
        var matched_atom: ?SimpleClassSequenceAtom = null;
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            const atom = alternative.atoms[0];
            if (simpleClassSequenceAtomMatches(atom, units[index])) {
                matched_atom = atom;
                break;
            }
        }

        const atom = matched_atom orelse {
            if (sticky) break;
            index += 1;
            continue;
        };
        const match_start = index;
        index += 1;
        if (atom.max_repeat == std.math.maxInt(usize)) {
            while (index < units.len and simpleClassSequenceAtomMatches(atom, units[index])) : (index += 1) {}
        }
        const len = index - match_start;
        total_len += len;
        match_count += 1;
        last_found = .{ .index = match_start, .len = len };
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationLengthLoopLatin1(pattern: SimpleClassAlternationPattern, bytes: []const u8, start: usize, sticky: bool, flags: []const u8) ?SimpleClassAlternationLengthLoopResult {
    if (simpleClassAlternationLiteralLengthLoopLatin1(pattern, bytes, start, sticky)) |result| return result;
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index <= bytes.len) {
        var matched: ?RegExpMatch = null;
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (simpleClassSequenceAtLatin1(alternative, bytes, index, flags)) |found| {
                matched = found;
                break;
            }
        }
        if (matched) |found| {
            if (found.len == 0) return null;
            total_len = std.math.add(usize, total_len, found.len) catch return null;
            match_count += 1;
            last_found = found;
            index = found.index + found.len;
            continue;
        }
        if (sticky) break;
        index += 1;
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationLengthLoopUtf16(pattern: SimpleClassAlternationPattern, units: []const u16, start: usize, sticky: bool, flags: []const u8) ?SimpleClassAlternationLengthLoopResult {
    if (simpleClassAlternationLiteralLengthLoopUtf16(pattern, units, start, sticky)) |result| return result;
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > units.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index <= units.len) {
        var matched: ?RegExpMatch = null;
        for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (simpleClassSequenceAtUtf16(alternative, units, index, flags)) |found| {
                matched = found;
                break;
            }
        }
        if (matched) |found| {
            if (found.len == 0) return null;
            total_len = std.math.add(usize, total_len, found.len) catch return null;
            match_count += 1;
            last_found = found;
            index = found.index + found.len;
            continue;
        }
        if (sticky) break;
        index += 1;
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationLiteralLengthLoopLatin1(pattern: SimpleClassAlternationPattern, bytes: []const u8, start: usize, sticky: bool) ?SimpleClassAlternationLengthLoopResult {
    if (!simpleClassAlternationAllUnitLiterals(pattern, true)) return null;
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index < bytes.len) {
        var matched_len: usize = 0;
        alternatives: for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (index + alternative.len > bytes.len) continue;
            for (alternative.atoms[0..alternative.len], 0..) |atom, offset| {
                if (bytes[index + offset] != @as(u8, @intCast(atom.literal))) continue :alternatives;
            }
            matched_len = alternative.len;
            break;
        }
        if (matched_len != 0) {
            total_len = std.math.add(usize, total_len, matched_len) catch return null;
            match_count += 1;
            last_found = .{ .index = index, .len = matched_len };
            index += matched_len;
            continue;
        }
        if (sticky) break;
        index += 1;
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationLiteralLengthLoopUtf16(pattern: SimpleClassAlternationPattern, units: []const u16, start: usize, sticky: bool) ?SimpleClassAlternationLengthLoopResult {
    if (!simpleClassAlternationAllUnitLiterals(pattern, false)) return null;
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > units.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };

    var index = start;
    while (index < units.len) {
        var matched_len: usize = 0;
        alternatives: for (pattern.alternatives[0..pattern.len]) |alternative| {
            if (index + alternative.len > units.len) continue;
            for (alternative.atoms[0..alternative.len], 0..) |atom, offset| {
                if (units[index + offset] != atom.literal) continue :alternatives;
            }
            matched_len = alternative.len;
            break;
        }
        if (matched_len != 0) {
            total_len = std.math.add(usize, total_len, matched_len) catch return null;
            match_count += 1;
            last_found = .{ .index = index, .len = matched_len };
            index += matched_len;
            continue;
        }
        if (sticky) break;
        index += 1;
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassAlternationAllUnitLiterals(pattern: SimpleClassAlternationPattern, comptime latin1: bool) bool {
    if (pattern.len < 2) return false;
    for (pattern.alternatives[0..pattern.len]) |alternative| {
        if (alternative.len == 0 or alternative.anchor_start or alternative.anchor_end) return false;
        for (alternative.atoms[0..alternative.len]) |atom| {
            if (atom.kind != .literal or atom.min_repeat != 1 or atom.max_repeat != 1) return false;
            if (latin1 and atom.literal > 0xff) return false;
        }
    }
    return true;
}

pub fn simpleCaptureSequenceTwoRunLengthSumLoopLatin1(pattern: SimpleCaptureSequencePattern, bytes: []const u8, start: usize, sticky: bool, capture_indexes: []const u8) ?SimpleCaptureLengthSumLoopResult {
    if (pattern.anchor_start or pattern.anchor_end or pattern.len != 2 or pattern.capture_count < 2) return null;
    const first = pattern.atoms[0];
    const second = pattern.atoms[1];
    if (first.capture_index == null or second.capture_index == null) return null;
    if (first.min_repeat != 1 or first.max_repeat != std.math.maxInt(usize)) return null;
    if (second.min_repeat != 1 or second.max_repeat != std.math.maxInt(usize)) return null;
    if (!simpleCaptureAtomsKnownDisjoint(first, second)) return null;

    var total_sum: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_sum = 0, .last_found = null };

    var index = start;
    while (index < bytes.len) {
        if (!simpleCaptureSequenceAtomMatches(first, bytes[index])) {
            if (sticky) break;
            index += 1;
            continue;
        }
        const match_start = index;
        const first_start = index;
        index += 1;
        while (index < bytes.len and simpleCaptureSequenceAtomMatches(first, bytes[index])) : (index += 1) {}
        const first_len = index - first_start;
        if (index >= bytes.len or !simpleCaptureSequenceAtomMatches(second, bytes[index])) {
            if (sticky) break;
            index = match_start + 1;
            continue;
        }
        const second_start = index;
        index += 1;
        while (index < bytes.len and simpleCaptureSequenceAtomMatches(second, bytes[index])) : (index += 1) {}
        const second_len = index - second_start;
        const match_len = index - match_start;

        var found = RegExpMatch{ .index = match_start, .len = match_len, .capture_count = pattern.capture_count };
        initFastCaptures(&found.captures, pattern.capture_count);
        found.captures[first.capture_index.? - 1] = .{ .start = first_start, .len = first_len };
        found.captures[second.capture_index.? - 1] = .{ .start = second_start, .len = second_len };
        const sum = captureLengthSum(found, capture_indexes) orelse return null;
        total_sum = std.math.add(usize, total_sum, sum) catch return null;
        last_found = found;
    }
    return .{ .total_sum = total_sum, .last_found = last_found };
}

pub fn simpleCaptureSequenceLengthSumLoopLatin1(pattern: SimpleCaptureSequencePattern, bytes: []const u8, start: usize, sticky: bool, flags: []const u8, capture_indexes: []const u8) ?SimpleCaptureLengthSumLoopResult {
    if (simpleCaptureSequenceTwoRunLengthSumLoopLatin1(pattern, bytes, start, sticky, capture_indexes)) |result| return result;
    var total_sum: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_sum = 0, .last_found = null };

    var index = start;
    while (index <= bytes.len) {
        const found = simpleCaptureSequenceAtLatin1(pattern, bytes, index, flags) orelse {
            if (sticky) break;
            index += 1;
            continue;
        };
        if (found.len == 0) return null;
        const sum = captureLengthSum(found, capture_indexes) orelse return null;
        total_sum = std.math.add(usize, total_sum, sum) catch return null;
        last_found = found;
        index = found.index + found.len;
    }
    return .{ .total_sum = total_sum, .last_found = last_found };
}

pub fn simpleCaptureSequenceLengthSumLoopUtf16(pattern: SimpleCaptureSequencePattern, units: []const u16, start: usize, sticky: bool, flags: []const u8, capture_indexes: []const u8) ?SimpleCaptureLengthSumLoopResult {
    var total_sum: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > units.len) return .{ .total_sum = 0, .last_found = null };

    var index = start;
    while (index <= units.len) {
        const found = simpleCaptureSequenceAtUtf16(pattern, units, index, flags) orelse {
            if (sticky) break;
            index += 1;
            continue;
        };
        if (found.len == 0) return null;
        const sum = captureLengthSum(found, capture_indexes) orelse return null;
        total_sum = std.math.add(usize, total_sum, sum) catch return null;
        last_found = found;
        index = found.index + found.len;
    }
    return .{ .total_sum = total_sum, .last_found = last_found };
}

pub fn simpleClassSequenceSingleUnitLengthLoopLatin1(atom: SimpleClassSequenceAtom, bytes: []const u8, start: usize, sticky: bool) SimpleClassSequenceLengthLoopResult {
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > bytes.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };
    if (sticky) {
        var index = start;
        while (index < bytes.len and simpleClassSequenceAtomMatches(atom, bytes[index])) : (index += 1) {
            total_len += 1;
            match_count += 1;
            last_found = .{ .index = index, .len = 1 };
        }
        return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
    }
    var index = start;
    while (index < bytes.len) : (index += 1) {
        if (simpleClassSequenceAtomMatches(atom, bytes[index])) {
            total_len += 1;
            match_count += 1;
            last_found = .{ .index = index, .len = 1 };
        }
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn simpleClassSequenceSingleUnitLengthLoopUtf16(atom: SimpleClassSequenceAtom, units: []const u16, start: usize, sticky: bool) SimpleClassSequenceLengthLoopResult {
    var total_len: usize = 0;
    var match_count: usize = 0;
    var last_found: ?RegExpMatch = null;
    if (start > units.len) return .{ .total_len = 0, .match_count = 0, .last_found = null };
    if (sticky) {
        var index = start;
        while (index < units.len and simpleClassSequenceAtomMatches(atom, units[index])) : (index += 1) {
            total_len += 1;
            match_count += 1;
            last_found = .{ .index = index, .len = 1 };
        }
        return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
    }
    var index = start;
    while (index < units.len) : (index += 1) {
        if (simpleClassSequenceAtomMatches(atom, units[index])) {
            total_len += 1;
            match_count += 1;
            last_found = .{ .index = index, .len = 1 };
        }
    }
    return .{ .total_len = total_len, .match_count = match_count, .last_found = last_found };
}

pub fn parseSimpleUnicodeLiteralSource(source: []const u8) ?SimpleUnicodeLiteralPattern {
    if (source.len == 0) return null;
    if (std.mem.indexOf(u8, source, "\\0") == null and std.mem.indexOf(u8, source, "\\u{") == null) return null;
    var pattern = SimpleUnicodeLiteralPattern{};
    var index: usize = 0;
    if (source[index] == '^') {
        pattern.anchor_start = true;
        index += 1;
    }
    const end_limit = if (source.len > index and source[source.len - 1] == '$') blk: {
        pattern.anchor_end = true;
        break :blk source.len - 1;
    } else source.len;
    while (index < end_limit) {
        if (pattern.len >= pattern.units.len) return null;
        if (source[index] == '\\') {
            if (index + 1 >= end_limit) return null;
            switch (source[index + 1]) {
                '0' => {
                    if (index + 2 < end_limit and std.ascii.isDigit(source[index + 2])) return null;
                    pattern.units[pattern.len] = 0;
                    pattern.len += 1;
                    index += 2;
                },
                'u' => {
                    if (index + 2 < end_limit and source[index + 2] == '{') {
                        var scan = index + 3;
                        var saw_digit = false;
                        var value: u32 = 0;
                        while (scan < end_limit and source[scan] != '}') : (scan += 1) {
                            const digit = std.fmt.charToDigit(source[scan], 16) catch return null;
                            saw_digit = true;
                            if (value > 0x10ffff / 16) return null;
                            value = value * 16 + digit;
                            if (value > 0x10ffff) return null;
                        }
                        if (!saw_digit or scan >= end_limit or source[scan] != '}') return null;
                        if (value <= 0xffff) {
                            pattern.units[pattern.len] = @intCast(value);
                            pattern.len += 1;
                        } else {
                            if (pattern.len + 2 > pattern.units.len) return null;
                            const cp = value - 0x10000;
                            pattern.units[pattern.len] = @intCast(0xd800 + (cp >> 10));
                            pattern.units[pattern.len + 1] = @intCast(0xdc00 + (cp & 0x3ff));
                            pattern.len += 2;
                        }
                        index = scan + 1;
                        continue;
                    }
                    if (index + 6 > end_limit) return null;
                    var value: u16 = 0;
                    var digit_index = index + 2;
                    while (digit_index < index + 6) : (digit_index += 1) {
                        const digit = std.fmt.charToDigit(source[digit_index], 16) catch return null;
                        value = value * 16 + @as(u16, @intCast(digit));
                    }
                    pattern.units[pattern.len] = value;
                    pattern.len += 1;
                    index += 6;
                },
                else => return null,
            }
            continue;
        }
        if (isRegExpSyntaxByte(source[index])) return null;
        const width = std.unicode.utf8ByteSequenceLength(source[index]) catch return null;
        if (index + width > end_limit) return null;
        const cp = std.unicode.utf8Decode(source[index .. index + width]) catch return null;
        if (cp <= 0xffff) {
            pattern.units[pattern.len] = @intCast(cp);
            pattern.len += 1;
        } else {
            if (pattern.len + 2 > pattern.units.len) return null;
            const adjusted = cp - 0x10000;
            pattern.units[pattern.len] = @intCast(0xd800 + (adjusted >> 10));
            pattern.units[pattern.len + 1] = @intCast(0xdc00 + (adjusted & 0x3ff));
            pattern.len += 2;
        }
        index += width;
    }
    return if (pattern.len == 0) null else pattern;
}

pub fn parseSimpleClassSequenceSource(source: []const u8, flags: []const u8) ?SimpleClassSequencePattern {
    return parseSimpleClassSequenceSourceWithEncoding(source, flags, .utf8);
}

pub fn parseSimpleClassSequenceLatin1Source(source: []const u8, flags: []const u8) ?SimpleClassSequencePattern {
    return parseSimpleClassSequenceSourceWithEncoding(source, flags, .latin1);
}

const SimpleClassSequenceSourceEncoding = enum {
    utf8,
    latin1,
};

fn parseSimpleClassSequenceSourceWithEncoding(source: []const u8, flags: []const u8, comptime encoding: SimpleClassSequenceSourceEncoding) ?SimpleClassSequencePattern {
    if (source.len == 0 or hasFlag(flags, 'i')) return null;
    if (hasFlag(flags, 'v') and std.mem.indexOfScalar(u8, source, '[') != null) return null;
    var pattern = SimpleClassSequencePattern{};
    var has_required_atom = false;
    var index: usize = 0;
    if (source[index] == '^') {
        pattern.anchor_start = true;
        index += 1;
    }
    const end_limit = if (source.len > index and source[source.len - 1] == '$') blk: {
        pattern.anchor_end = true;
        break :blk source.len - 1;
    } else source.len;
    while (index < end_limit) {
        if (pattern.len >= pattern.atoms.len) return null;
        var atom = SimpleClassSequenceAtom{};
        if (source[index] == '[') {
            const class_end = findCharacterClassEnd(source, index) orelse return null;
            if (class_end >= end_limit) return null;
            atom.kind = .class;
            atom.class_source = source[index .. class_end + 1];
            atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
            index = class_end + 1;
        } else if (source[index] == '\\') {
            if (index + 1 >= end_limit) return null;
            if (index + 2 < end_limit and source[index + 1] == '\\' and isSimpleClassEscapeByte(source[index + 2])) {
                atom.kind = .class;
                atom.class_source = source[index + 1 .. index + 3];
                atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
                index += 3;
            } else switch (source[index + 1]) {
                'd', 'D', 's', 'S', 'w', 'W' => {
                    atom.kind = .class;
                    atom.class_source = source[index .. index + 2];
                    atom.class_predicate = simpleClassPredicateFromSource(atom.class_source);
                    index += 2;
                },
                else => {
                    atom.kind = .literal;
                    atom.literal = parseSimpleClassSequenceEscapedLiteral(source, &index, end_limit) orelse return null;
                },
            }
        } else {
            atom.kind = .literal;
            atom.literal = switch (encoding) {
                .utf8 => parseSimpleClassSequenceLiteral(source, &index, end_limit),
                .latin1 => parseSimpleClassSequenceLatin1Literal(source, &index, end_limit),
            } orelse return null;
        }

        if (index < end_limit) {
            switch (source[index]) {
                '*' => {
                    atom.min_repeat = 0;
                    atom.max_repeat = std.math.maxInt(usize);
                    index += 1;
                },
                '+' => {
                    atom.max_repeat = std.math.maxInt(usize);
                    index += 1;
                },
                '?' => {
                    atom.min_repeat = 0;
                    atom.max_repeat = 1;
                    index += 1;
                },
                '{', '(', ')', '|' => return null,
                else => {},
            }
        }
        if (atom.min_repeat > 0) has_required_atom = true;
        pattern.atoms[pattern.len] = atom;
        pattern.len += 1;
    }
    if (pattern.len == 0 or !has_required_atom) return null;
    return pattern;
}

pub fn parseSimpleClassAlternationSource(source: []const u8, flags: []const u8) ?SimpleClassAlternationPattern {
    if (source.len == 0 or hasFlag(flags, 'i')) return null;

    var pattern = SimpleClassAlternationPattern{};
    var part_start: usize = 0;
    var index: usize = 0;
    var saw_alternation = false;
    while (index < source.len) {
        switch (source[index]) {
            '\\' => {
                if (index + 1 >= source.len) return null;
                index += 2;
                continue;
            },
            '[' => {
                const class_end = findCharacterClassEnd(source, index) orelse return null;
                index = class_end + 1;
                continue;
            },
            '|' => {
                saw_alternation = true;
                addSimpleClassAlternationPart(&pattern, source[part_start..index], flags) orelse return null;
                part_start = index + 1;
            },
            else => {},
        }
        index += 1;
    }

    if (!saw_alternation) return null;
    addSimpleClassAlternationPart(&pattern, source[part_start..], flags) orelse return null;
    return if (pattern.len >= 2) pattern else null;
}

pub fn addSimpleClassAlternationPart(pattern: *SimpleClassAlternationPattern, source: []const u8, flags: []const u8) ?void {
    if (pattern.len >= pattern.alternatives.len) return null;
    if (source.len == 0) return null;
    const alternative = parseSimpleClassSequenceSource(source, flags) orelse return null;
    if (alternative.anchor_start or alternative.anchor_end) return null;
    pattern.alternatives[pattern.len] = alternative;
    pattern.len += 1;
}

pub fn isSimpleClassEscapeByte(byte: u8) bool {
    return switch (byte) {
        'd', 'D', 's', 'S', 'w', 'W' => true,
        else => false,
    };
}

pub fn simpleUnicodeLiteralAt(pattern: SimpleUnicodeLiteralPattern, string_value: core.string.String, pos: usize, flags: []const u8) ?RegExpMatch {
    if (pattern.anchor_start and !isStringLineStartPosition(string_value, pos, hasFlag(flags, 'm'))) return null;
    if (pos + pattern.len > string_value.len()) return null;
    for (pattern.units[0..pattern.len], 0..) |unit, offset| {
        if (string_value.codeUnitAt(pos + offset) != unit) return null;
    }
    if (pattern.anchor_end and !isStringLineEndPosition(string_value, pos + pattern.len, hasFlag(flags, 'm'))) return null;
    return RegExpMatch{ .index = pos, .len = pattern.len };
}

pub fn simpleClassSequenceAtLatin1(pattern: SimpleClassSequencePattern, bytes: []const u8, pos: usize, flags: []const u8) ?RegExpMatch {
    if (pattern.anchor_start and !isBytesLineStartPosition(bytes, pos, hasFlag(flags, 'm'))) return null;
    const end = simpleClassSequenceBacktrackLatin1(pattern, bytes, 0, pos, flags) orelse return null;
    return RegExpMatch{ .index = pos, .len = end - pos };
}

pub fn simpleCaptureSequenceAtLatin1(pattern: SimpleCaptureSequencePattern, bytes: []const u8, pos: usize, flags: []const u8) ?RegExpMatch {
    if (pattern.anchor_start and !isBytesLineStartPosition(bytes, pos, hasFlag(flags, 'm'))) return null;
    var captures: [256]RegExpCapture = undefined;
    initFastCaptures(&captures, pattern.capture_count);
    const end = simpleCaptureSequenceBacktrackLatin1(pattern, bytes, 0, pos, flags, &captures) orelse return null;
    var found = RegExpMatch{ .index = pos, .len = end - pos, .capture_count = pattern.capture_count };
    @memcpy(found.captures[0..pattern.capture_count], captures[0..pattern.capture_count]);
    return found;
}

pub fn simpleClassSequenceAtUtf16(pattern: SimpleClassSequencePattern, units: []const u16, pos: usize, flags: []const u8) ?RegExpMatch {
    if (pattern.anchor_start and !isUnitsLineStartPosition(units, pos, hasFlag(flags, 'm'))) return null;
    const end = simpleClassSequenceBacktrackUtf16(pattern, units, 0, pos, flags) orelse return null;
    return RegExpMatch{ .index = pos, .len = end - pos };
}

pub fn simpleCaptureSequenceAtUtf16(pattern: SimpleCaptureSequencePattern, units: []const u16, pos: usize, flags: []const u8) ?RegExpMatch {
    if (pattern.anchor_start and !isUnitsLineStartPosition(units, pos, hasFlag(flags, 'm'))) return null;
    var captures: [256]RegExpCapture = undefined;
    initFastCaptures(&captures, pattern.capture_count);
    const end = simpleCaptureSequenceBacktrackUtf16(pattern, units, 0, pos, flags, &captures) orelse return null;
    var found = RegExpMatch{ .index = pos, .len = end - pos, .capture_count = pattern.capture_count };
    @memcpy(found.captures[0..pattern.capture_count], captures[0..pattern.capture_count]);
    return found;
}

pub fn simpleClassSequenceBacktrackLatin1(
    pattern: SimpleClassSequencePattern,
    bytes: []const u8,
    atom_index: usize,
    pos: usize,
    flags: []const u8,
) ?usize {
    if (atom_index == pattern.len) {
        if (pattern.anchor_end and !isBytesLineEndPosition(bytes, pos, hasFlag(flags, 'm'))) return null;
        return pos;
    }

    const atom = pattern.atoms[atom_index];
    var count: usize = 0;
    var end = pos;
    while (count < atom.max_repeat and end < bytes.len and simpleClassSequenceAtomMatches(atom, bytes[end])) {
        count += 1;
        end += 1;
    }
    if (count < atom.min_repeat) return null;

    var try_count = count;
    while (true) {
        if (simpleClassSequenceBacktrackLatin1(pattern, bytes, atom_index + 1, pos + try_count, flags)) |matched_end| return matched_end;
        if (try_count == atom.min_repeat) break;
        try_count -= 1;
    }
    return null;
}

pub fn simpleCaptureSequenceBacktrackLatin1(
    pattern: SimpleCaptureSequencePattern,
    bytes: []const u8,
    atom_index: usize,
    pos: usize,
    flags: []const u8,
    captures: *[256]RegExpCapture,
) ?usize {
    if (atom_index == pattern.len) {
        if (pattern.anchor_end and !isBytesLineEndPosition(bytes, pos, hasFlag(flags, 'm'))) return null;
        return pos;
    }

    const atom = pattern.atoms[atom_index];
    var count: usize = 0;
    var end = pos;
    while (count < atom.max_repeat and end < bytes.len and simpleCaptureSequenceAtomMatches(atom, bytes[end])) {
        count += 1;
        end += 1;
    }
    if (count < atom.min_repeat) return null;

    var try_count = count;
    while (true) {
        const saved_capture = if (atom.capture_index) |capture_index| blk: {
            const slot = capture_index - 1;
            const saved = captures[slot];
            captures[slot] = .{ .start = pos, .len = try_count };
            break :blk saved;
        } else null;
        if (simpleCaptureSequenceBacktrackLatin1(pattern, bytes, atom_index + 1, pos + try_count, flags, captures)) |matched_end| return matched_end;
        if (atom.capture_index) |capture_index| captures[capture_index - 1] = saved_capture.?;
        if (try_count == atom.min_repeat) break;
        try_count -= 1;
    }
    return null;
}

pub fn simpleClassSequenceBacktrackUtf16(
    pattern: SimpleClassSequencePattern,
    units: []const u16,
    atom_index: usize,
    pos: usize,
    flags: []const u8,
) ?usize {
    if (atom_index == pattern.len) {
        if (pattern.anchor_end and !isUnitsLineEndPosition(units, pos, hasFlag(flags, 'm'))) return null;
        return pos;
    }

    const atom = pattern.atoms[atom_index];
    var count: usize = 0;
    var end = pos;
    while (count < atom.max_repeat and end < units.len and simpleClassSequenceAtomMatches(atom, units[end])) {
        count += 1;
        end += 1;
    }
    if (count < atom.min_repeat) return null;

    var try_count = count;
    while (true) {
        if (simpleClassSequenceBacktrackUtf16(pattern, units, atom_index + 1, pos + try_count, flags)) |matched_end| return matched_end;
        if (try_count == atom.min_repeat) break;
        try_count -= 1;
    }
    return null;
}

pub fn simpleCaptureSequenceBacktrackUtf16(
    pattern: SimpleCaptureSequencePattern,
    units: []const u16,
    atom_index: usize,
    pos: usize,
    flags: []const u8,
    captures: *[256]RegExpCapture,
) ?usize {
    if (atom_index == pattern.len) {
        if (pattern.anchor_end and !isUnitsLineEndPosition(units, pos, hasFlag(flags, 'm'))) return null;
        return pos;
    }

    const atom = pattern.atoms[atom_index];
    var count: usize = 0;
    var end = pos;
    while (count < atom.max_repeat and end < units.len and simpleCaptureSequenceAtomMatches(atom, units[end])) {
        count += 1;
        end += 1;
    }
    if (count < atom.min_repeat) return null;

    var try_count = count;
    while (true) {
        const saved_capture = if (atom.capture_index) |capture_index| blk: {
            const slot = capture_index - 1;
            const saved = captures[slot];
            captures[slot] = .{ .start = pos, .len = try_count };
            break :blk saved;
        } else null;
        if (simpleCaptureSequenceBacktrackUtf16(pattern, units, atom_index + 1, pos + try_count, flags, captures)) |matched_end| return matched_end;
        if (atom.capture_index) |capture_index| captures[capture_index - 1] = saved_capture.?;
        if (try_count == atom.min_repeat) break;
        try_count -= 1;
    }
    return null;
}

pub fn simpleClassPredicateFromSource(source: []const u8) SimpleClassPredicate {
    if (std.mem.eql(u8, source, "\\d")) return .ascii_digit;
    if (std.mem.eql(u8, source, "\\D")) return .ascii_not_digit;
    if (std.mem.eql(u8, source, "\\w")) return .ascii_word;
    if (std.mem.eql(u8, source, "\\W")) return .ascii_not_word;
    if (std.mem.eql(u8, source, "[a-z]")) return .ascii_lower;
    if (std.mem.eql(u8, source, "[A-Za-z]")) return .ascii_alpha;
    if (std.mem.eql(u8, source, "[0-9]")) return .ascii_decimal;
    return .generic;
}

pub fn initFastCaptures(captures: *[256]RegExpCapture, capture_count: usize) void {
    var index: usize = 0;
    while (index < capture_count) : (index += 1) {
        captures[index] = .{ .start = 0, .len = 0, .undefined = true };
    }
}

pub fn parseSimpleClassSequenceLiteral(source: []const u8, index: *usize, end_limit: usize) ?u16 {
    if (index.* >= end_limit or isRegExpSyntaxByte(source[index.*])) return null;
    const width = std.unicode.utf8ByteSequenceLength(source[index.*]) catch return null;
    if (index.* + width > end_limit) return null;
    const code_point = std.unicode.utf8Decode(source[index.* .. index.* + width]) catch return null;
    if (code_point > 0xffff) return null;
    index.* += width;
    return @intCast(code_point);
}

pub fn parseSimpleClassSequenceLatin1Literal(source: []const u8, index: *usize, end_limit: usize) ?u16 {
    if (index.* >= end_limit or isRegExpSyntaxByte(source[index.*])) return null;
    const unit = source[index.*];
    index.* += 1;
    return unit;
}

test "Latin1 RegExp source parser accepts raw non-ASCII simple literal sequence" {
    const latin1_source = [_]u8{ 0xe9, '+' };
    const pattern = parseSimpleClassSequenceLatin1Source(&latin1_source, "") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), pattern.len);
    try std.testing.expectEqual(@as(u16, 0xe9), pattern.atoms[0].literal);
    try std.testing.expectEqual(@as(usize, 1), pattern.atoms[0].min_repeat);
    try std.testing.expectEqual(std.math.maxInt(usize), pattern.atoms[0].max_repeat);
    try std.testing.expect(parseSimpleClassSequenceSource(&latin1_source, "") == null);
}

pub fn parseSimpleClassSequenceEscapedLiteral(source: []const u8, index: *usize, end_limit: usize) ?u16 {
    if (index.* + 1 >= end_limit or source[index.*] != '\\') return null;
    const escaped = source[index.* + 1];
    switch (escaped) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => {
            index.* += 2;
            return escaped;
        },
        '0' => {
            if (index.* + 2 < end_limit and std.ascii.isDigit(source[index.* + 2])) return null;
            index.* += 2;
            return 0;
        },
        'f' => {
            index.* += 2;
            return 0x0c;
        },
        'n' => {
            index.* += 2;
            return '\n';
        },
        'r' => {
            index.* += 2;
            return '\r';
        },
        't' => {
            index.* += 2;
            return '\t';
        },
        'v' => {
            index.* += 2;
            return 0x0b;
        },
        'c' => {
            if (index.* + 2 >= end_limit or !std.ascii.isAlphabetic(source[index.* + 2])) return null;
            const value: u16 = source[index.* + 2] & 0x1f;
            index.* += 3;
            return value;
        },
        'x' => {
            if (index.* + 4 > end_limit) return null;
            var value: u16 = 0;
            var digit_index = index.* + 2;
            while (digit_index < index.* + 4) : (digit_index += 1) {
                const digit = std.fmt.charToDigit(source[digit_index], 16) catch return null;
                value = value * 16 + @as(u16, @intCast(digit));
            }
            index.* += 4;
            return value;
        },
        'u' => {
            if (index.* + 2 < end_limit and source[index.* + 2] == '{') {
                var scan = index.* + 3;
                var saw_digit = false;
                var value: u32 = 0;
                while (scan < end_limit and source[scan] != '}') : (scan += 1) {
                    const digit = std.fmt.charToDigit(source[scan], 16) catch return null;
                    saw_digit = true;
                    if (value > 0xffff / 16) return null;
                    value = value * 16 + digit;
                    if (value > 0xffff) return null;
                }
                if (!saw_digit or scan >= end_limit or source[scan] != '}') return null;
                index.* = scan + 1;
                return @intCast(value);
            }
            if (index.* + 6 > end_limit) return null;
            var value: u16 = 0;
            var digit_index = index.* + 2;
            while (digit_index < index.* + 6) : (digit_index += 1) {
                const digit = std.fmt.charToDigit(source[digit_index], 16) catch return null;
                value = value * 16 + @as(u16, @intCast(digit));
            }
            index.* += 6;
            return value;
        },
        else => return null,
    }
}

pub fn isBytesLineStartPosition(bytes: []const u8, pos: usize, multiline: bool) bool {
    if (pos == 0) return true;
    if (!multiline or pos > bytes.len) return false;
    return bytes[pos - 1] == '\n' or bytes[pos - 1] == '\r';
}

pub fn isBytesLineEndPosition(bytes: []const u8, pos: usize, multiline: bool) bool {
    if (pos == bytes.len) return true;
    if (!multiline or pos > bytes.len) return false;
    return bytes[pos] == '\n' or bytes[pos] == '\r';
}

pub fn isUnitsLineStartPosition(units: []const u16, pos: usize, multiline: bool) bool {
    if (pos == 0) return true;
    if (!multiline or pos > units.len) return false;
    return isLineTerminatorUnit(units[pos - 1]);
}

pub fn isUnitsLineEndPosition(units: []const u16, pos: usize, multiline: bool) bool {
    if (pos == units.len) return true;
    if (!multiline or pos > units.len) return false;
    return isLineTerminatorUnit(units[pos]);
}

pub fn isLineTerminatorUnit(unit: u16) bool {
    return unit == '\n' or unit == '\r' or unit == 0x2028 or unit == 0x2029;
}

pub const SurrogatePairClassPattern = struct {
    high: u16,
    low: u16,
    anchor_start: bool,
    anchor_end: bool,
};

pub fn parseSurrogatePairClassSource(source: []const u8) ?SurrogatePairClassPattern {
    var index: usize = 0;
    const anchor_start = source.len > 0 and source[0] == '^';
    if (anchor_start) index += 1;
    if (index >= source.len or source[index] != '[') return null;
    index += 1;
    const high = readFixedUnicodeEscapeUnit(source, &index) orelse return null;
    const low = readFixedUnicodeEscapeUnit(source, &index) orelse return null;
    if (!isHighSurrogateUnit(high) or !isLowSurrogateUnit(low)) return null;
    if (index >= source.len or source[index] != ']') return null;
    index += 1;
    const anchor_end = index < source.len and source[index] == '$';
    if (anchor_end) index += 1;
    if (index != source.len) return null;
    return .{ .high = high, .low = low, .anchor_start = anchor_start, .anchor_end = anchor_end };
}

pub fn readFixedUnicodeEscapeUnit(source: []const u8, index: *usize) ?u16 {
    if (index.* + 6 > source.len or source[index.*] != '\\' or source[index.* + 1] != 'u') return null;
    var value: u16 = 0;
    var pos = index.* + 2;
    while (pos < index.* + 6) : (pos += 1) {
        const digit = std.fmt.charToDigit(source[pos], 16) catch return null;
        value = value * 16 + @as(u16, @intCast(digit));
    }
    index.* += 6;
    return value;
}

pub fn surrogatePairClassAt(pattern: SurrogatePairClassPattern, string_value: core.string.String, pos: usize) ?RegExpMatch {
    if (pattern.anchor_start and pos != 0) return null;
    if (pos + 2 > string_value.len()) return null;
    if (string_value.codeUnitAt(pos) != pattern.high or string_value.codeUnitAt(pos + 1) != pattern.low) return null;
    if (pattern.anchor_end and pos + 2 != string_value.len()) return null;
    return .{ .index = pos, .len = 2 };
}

pub const UnicodeAstralSpecialPattern = union(enum) {
    repeat: struct {
        high: u16,
        low: u16,
        count: usize,
    },
    range: struct {
        lo: u21,
        hi: u21,
    },
    exact_class: struct {
        high: u16,
        low: u16,
        anchor_start: bool,
        anchor_end: bool,
    },
    negated_pair: struct {
        high: u16,
        low: u16,
    },
};

pub fn parseUnicodeAstralSpecialSource(source: []const u8) ?UnicodeAstralSpecialPattern {
    if (source.len == 0) return null;
    if (source[0] == '[' or source[0] == '^') return parseUnicodeAstralClassSpecialSource(source);

    var index: usize = 0;
    const pair = readAstralAtom(source, &index) orelse return null;
    if (index >= source.len or source[index] != '{') return null;
    index += 1;
    if (index >= source.len or source[index] < '0' or source[index] > '9') return null;
    var count: usize = 0;
    while (index < source.len and source[index] >= '0' and source[index] <= '9') : (index += 1) {
        count = count * 10 + (source[index] - '0');
    }
    if (index >= source.len or source[index] != '}' or count == 0) return null;
    index += 1;
    if (index != source.len) return null;
    return .{ .repeat = .{ .high = pair.high, .low = pair.low, .count = count } };
}

pub fn parseUnicodeAstralClassSpecialSource(source: []const u8) ?UnicodeAstralSpecialPattern {
    var index: usize = 0;
    const anchor_start = source[index] == '^';
    if (anchor_start) index += 1;
    if (index >= source.len) return null;
    if (source[index] != '[') return null;
    index += 1;
    const negated = index < source.len and source[index] == '^';
    if (negated) index += 1;
    const first = readAstralAtom(source, &index) orelse return null;
    if (negated) {
        if (index >= source.len or source[index] != ']') return null;
        index += 1;
        if (anchor_start) return null;
        if (index != source.len) return null;
        return .{ .negated_pair = .{ .high = first.high, .low = first.low } };
    }
    if (index < source.len and source[index] == ']') {
        index += 1;
        const anchor_end = index < source.len and source[index] == '$';
        if (anchor_end) index += 1;
        if (index != source.len) return null;
        return .{ .exact_class = .{ .high = first.high, .low = first.low, .anchor_start = anchor_start, .anchor_end = anchor_end } };
    }
    if (index >= source.len or source[index] != '-') return null;
    index += 1;
    const second = readAstralAtom(source, &index) orelse return null;
    if (index >= source.len or source[index] != ']') return null;
    index += 1;
    if (anchor_start) return null;
    if (index != source.len) return null;
    const lo = first.code_point;
    const hi = second.code_point;
    if (lo > hi) return null;
    return .{ .range = .{ .lo = lo, .hi = hi } };
}

pub const AstralAtom = struct {
    high: u16,
    low: u16,
    code_point: u21,
};

pub fn readAstralAtom(source: []const u8, index: *usize) ?AstralAtom {
    if (readSurrogatePairEscape(source, index)) |pair| {
        return .{ .high = pair.high, .low = pair.low, .code_point = codePointFromSurrogatePair(pair.high, pair.low) };
    }
    if (index.* >= source.len) return null;
    const width = std.unicode.utf8ByteSequenceLength(source[index.*]) catch return null;
    if (index.* + width > source.len) return null;
    const cp = std.unicode.utf8Decode(source[index.* .. index.* + width]) catch return null;
    if (cp <= 0xffff or cp > 0x10ffff) return null;
    index.* += width;
    const pair = surrogatePairFromCodePoint(@intCast(cp));
    return .{ .high = pair.high, .low = pair.low, .code_point = @intCast(cp) };
}

pub fn readSurrogatePairEscape(source: []const u8, index: *usize) ?struct { high: u16, low: u16 } {
    const high = readFixedUnicodeEscapeUnit(source, index) orelse return null;
    const low = readFixedUnicodeEscapeUnit(source, index) orelse return null;
    if (!isHighSurrogateUnit(high) or !isLowSurrogateUnit(low)) return null;
    return .{ .high = high, .low = low };
}

pub fn unicodeAstralSpecialAt(pattern: UnicodeAstralSpecialPattern, string_value: core.string.String, pos: usize) ?RegExpMatch {
    return switch (pattern) {
        .repeat => |repeat| repeatedSurrogatePairAt(repeat.high, repeat.low, repeat.count, string_value, pos),
        .range => |range| astralRangeAt(range.lo, range.hi, string_value, pos),
        .exact_class => |pair| exactSurrogatePairClassAt(pair.high, pair.low, pair.anchor_start, pair.anchor_end, string_value, pos),
        .negated_pair => |pair| negatedSurrogatePairClassAt(pair.high, pair.low, string_value, pos),
    };
}

pub fn repeatedSurrogatePairAt(high: u16, low: u16, count: usize, string_value: core.string.String, pos: usize) ?RegExpMatch {
    const len = count * 2;
    if (pos + len > string_value.len()) return null;
    var offset: usize = 0;
    while (offset < len) : (offset += 2) {
        if (string_value.codeUnitAt(pos + offset) != high or string_value.codeUnitAt(pos + offset + 1) != low) return null;
    }
    return .{ .index = pos, .len = len };
}

pub fn exactSurrogatePairClassAt(high: u16, low: u16, anchor_start: bool, anchor_end: bool, string_value: core.string.String, pos: usize) ?RegExpMatch {
    if (anchor_start and pos != 0) return null;
    if (pos + 2 > string_value.len()) return null;
    if (string_value.codeUnitAt(pos) != high or string_value.codeUnitAt(pos + 1) != low) return null;
    if (anchor_end and pos + 2 != string_value.len()) return null;
    return .{ .index = pos, .len = 2 };
}

pub fn astralRangeAt(lo: u21, hi: u21, string_value: core.string.String, pos: usize) ?RegExpMatch {
    const cp = stringCodePointAt(string_value, pos) orelse return null;
    if (cp.len != 2 or cp.value < lo or cp.value > hi) return null;
    return .{ .index = pos, .len = 2 };
}

pub fn negatedSurrogatePairClassAt(high: u16, low: u16, string_value: core.string.String, pos: usize) ?RegExpMatch {
    const cp = stringCodePointAt(string_value, pos) orelse return null;
    if (cp.len == 2 and string_value.codeUnitAt(pos) == high and string_value.codeUnitAt(pos + 1) == low) return null;
    return .{ .index = pos, .len = cp.len };
}

pub fn isRegExpLineTerminator(unit: u16) bool {
    return unit == '\n' or unit == '\r' or unit == 0x2028 or unit == 0x2029;
}

pub fn classEscapeRunLengthLatin1(source: []const u8, bytes: []const u8, start: usize) usize {
    if (!classEscapeIsQuantified(source)) return 1;
    var end = start;
    while (end < bytes.len and classEscapeUnitMatches(source, bytes[end])) : (end += 1) {}
    return end - start;
}

pub fn classEscapeRunLengthUtf16(source: []const u8, units: []const u16, start: usize) usize {
    if (!classEscapeIsQuantified(source)) return 1;
    var end = start;
    while (end < units.len and classEscapeUnitMatches(source, units[end])) : (end += 1) {}
    return end - start;
}

pub fn classEscapeIsQuantified(source: []const u8) bool {
    const kind_index = classEscapeKindIndex(source) orelse return false;
    return source.len == kind_index + 2 and source[kind_index + 1] == '+';
}

pub fn classEscapeKindIndex(source: []const u8) ?usize {
    if (source.len < 2 or source[0] != '\\') return null;
    if (source[1] == '\\') return if (source.len >= 3) 2 else null;
    return 1;
}

pub fn isEcmaWhitespaceOrLineTerminator(unit: u16) bool {
    return switch (unit) {
        0x0009...0x000d,
        0x0020,
        0x00a0,
        0x1680,
        0x2000...0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        0xfeff,
        => true,
        else => false,
    };
}
pub fn isUnknownScriptName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Script=Unknown") or
        std.mem.eql(u8, name, "Script=Zzzz") or
        std.mem.eql(u8, name, "sc=Unknown") or
        std.mem.eql(u8, name, "sc=Zzzz") or
        std.mem.eql(u8, name, "Script_Extensions=Unknown") or
        std.mem.eql(u8, name, "Script_Extensions=Zzzz") or
        std.mem.eql(u8, name, "scx=Unknown") or
        std.mem.eql(u8, name, "scx=Zzzz");
}
pub const exactScriptExtensionsAliasTarget = regexp_unicode.exactScriptExtensionsAliasTarget;

pub fn isAsciiDigitUnit(unit: u16) bool {
    return unicode_lib.isAsciiDigitUnit(unit);
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

pub const RegExpCapture = struct {
    start: usize,
    len: usize,
    undefined: bool = false,
    name: ?[]const u8 = null,
};

pub fn isRegExpSyntaxByte(byte: u8) bool {
    return switch (byte) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

pub fn hasFlag(flags: []const u8, flag: u8) bool {
    return std.mem.indexOfScalar(u8, flags, flag) != null;
}

pub fn regexpLastIndex(rt: *core.JSRuntime, object: *core.Object) usize {
    const value = object.getProperty(core.atom.ids.lastIndex);
    defer value.free(rt);
    if (value.asInt32()) |int_value| return if (int_value < 0) 0 else @intCast(int_value);
    if (value.asFloat64()) |float_value| {
        if (std.math.isNan(float_value) or float_value <= 0) return 0;
        if (float_value >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
        return @intFromFloat(@floor(float_value));
    }
    return 0;
}

pub fn setRegExpLastIndex(rt: *core.JSRuntime, object: *core.Object, index: usize) !void {
    const value = if (index <= @as(usize, @intCast(std.math.maxInt(i32))))
        core.JSValue.int32(@intCast(index))
    else
        core.JSValue.float64(@floatFromInt(index));
    object.setProperty(rt, core.atom.ids.lastIndex, value) catch return error.TypeError;
}

pub fn updateRegExpLegacyStaticsNoCaptures(rt: *core.JSRuntime, global: *core.Object, input_value: core.JSValue, found: RegExpMatch, input_len: usize) !void {
    const regexp_ctor = regExpConstructorFromGlobal(rt, global) catch return;
    if (regexp_ctor.class_payload_kind != .function) return;
    const legacy = try regexp_ctor.ensureRegExpLegacyStatics(rt);
    const already_lazy_no_capture = legacy.lazy_no_capture_match;

    try replaceRegExpLegacySlot(rt, regexp_ctor, &legacy.input, input_value);
    if (!already_lazy_no_capture) {
        clearRegExpLegacySlot(rt, &legacy.last_match);
        clearRegExpLegacySlot(rt, &legacy.left_context);
        clearRegExpLegacySlot(rt, &legacy.right_context);
        clearRegExpLegacySlot(rt, &legacy.last_paren);
        for (&legacy.captures) |*capture| clearRegExpLegacySlot(rt, capture);
    }

    legacy.lazy_no_capture_match = true;
    legacy.lazy_match_index = found.index;
    legacy.lazy_match_len = found.len;
    legacy.lazy_input_len = input_len;
}

pub fn createRegExpIndexPair(rt: *core.JSRuntime, global: *core.Object, start: usize, end: usize) !core.JSValue {
    const out = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &out.header);
    try defineSplitValueElement(rt, out, 0, core.JSValue.int32(@intCast(start)));
    try defineSplitValueElement(rt, out, 1, core.JSValue.int32(@intCast(end)));
    return out.value();
}

pub fn appendDecodedRegExpGroupName(rt: *core.JSRuntime, out: *std.ArrayList(u8), name: []const u8) !void {
    var index: usize = 0;
    while (index < name.len) {
        if (name[index] == '\\' and index + 1 < name.len and name[index + 1] == 'u') {
            if (readRegExpGroupNameEscape(name, &index)) |cp| {
                var code_point = cp;
                if (isHighSurrogateCodePoint(cp)) {
                    const saved = index;
                    if (readRegExpGroupNameEscape(name, &index)) |low| {
                        if (isLowSurrogateCodePoint(low)) {
                            code_point = combinedSurrogateCodePoint(@intCast(cp), @intCast(low));
                        } else {
                            index = saved;
                        }
                    } else {
                        index = saved;
                    }
                }
                try appendUtf8CodePointForRegExpName(rt, out, code_point);
                continue;
            }
        }
        try out.append(rt.memory.allocator, name[index]);
        index += 1;
    }
}

pub fn readRegExpGroupNameEscape(name: []const u8, index: *usize) ?u21 {
    if (index.* + 2 > name.len or name[index.*] != '\\' or name[index.* + 1] != 'u') return null;
    var pos = index.* + 2;
    if (pos < name.len and name[pos] == '{') {
        pos += 1;
        var value: u32 = 0;
        var saw_digit = false;
        while (pos < name.len and name[pos] != '}') : (pos += 1) {
            const digit = std.fmt.charToDigit(name[pos], 16) catch return null;
            saw_digit = true;
            value = value * 16 + digit;
            if (value > 0x10ffff) return null;
        }
        if (!saw_digit or pos >= name.len or name[pos] != '}') return null;
        index.* = pos + 1;
        return @intCast(value);
    }
    if (pos >= name.len or !std.ascii.isHex(name[pos])) return null;
    var available_hex: usize = 0;
    while (pos + available_hex < name.len and available_hex < 4 and std.ascii.isHex(name[pos + available_hex])) : (available_hex += 1) {}
    const digit_count: usize = if (available_hex >= 4) 4 else available_hex;
    var value: u32 = 0;
    var count: usize = 0;
    while (count < digit_count) : (count += 1) {
        const digit = std.fmt.charToDigit(name[pos + count], 16) catch return null;
        value = value * 16 + digit;
    }
    index.* = pos + digit_count;
    return @intCast(value);
}

pub fn toUint32Number(number: f64) u32 {
    if (std.math.isNan(number) or !std.math.isFinite(number) or number == 0) return 0;
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const modulo = @mod(integer, 4294967296.0);
    return @intFromFloat(modulo);
}

pub fn uint32NumberValue(value: u32) core.JSValue {
    if (value <= @as(u32, @intCast(std.math.maxInt(i32)))) return core.JSValue.int32(@intCast(value));
    return core.JSValue.float64(@floatFromInt(value));
}

pub fn coerceOptionalNumberMethodArgument(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    preserve_undefined: bool,
) !?core.JSValue {
    if (args.len == 0) return null;
    if (preserve_undefined and args[0].isUndefined()) return null;
    const primitive = try toPrimitiveForNumber(ctx, output, global, args[0]);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    return try value_ops.toNumberValue(ctx.runtime, primitive);
}

pub fn primitiveWrapperStoredValue(rt: *core.JSRuntime, value: core.JSValue) ?core.JSValue {
    _ = rt;
    if (!value.isObject()) return null;
    const object = property_ops.expectObject(value) catch return null;
    switch (object.class_id) {
        core.class.ids.number,
        core.class.ids.boolean,
        core.class.ids.big_int,
        core.class.ids.symbol,
        => if (object.objectData()) |stored| return stored.dup() else return null,
        else => return null,
    }
}

pub fn qjsFunctionHasInstanceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    return core.JSValue.boolean(try ordinaryHasInstance(ctx, output, global, this_value, value, caller_function, caller_frame));
}

pub fn ordinaryHasInstance(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (!isCallableValue(constructor_value)) return false;
    if (objectFromValue(constructor_value)) |constructor_object| {
        if (constructor_object.class_id == core.class.ids.bound_function) {
            const target = constructor_object.boundTarget() orelse return error.TypeError;
            return ordinaryHasInstance(ctx, output, global, target, value, caller_function, caller_frame);
        }
    }
    const object = objectFromValue(value) orelse return false;
    const proto_value = try getValueProperty(ctx, output, global, constructor_value, core.atom.ids.prototype, caller_function, caller_frame);
    defer proto_value.free(ctx.runtime);
    const prototype = objectFromValue(proto_value) orelse return error.TypeError;
    var current = try qjsObjectGetPrototypeOfStep(ctx, output, global, object, caller_function, caller_frame);
    while (current) |candidate| {
        if (candidate == prototype) return true;
        current = try qjsObjectGetPrototypeOfStep(ctx, output, global, candidate, caller_function, caller_frame);
    }
    return false;
}

pub fn qjsErrorStackGetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
) !core.JSValue {
    const object = objectFromValue(this_value) orelse return error.TypeError;
    if (object.class_id != core.class.ids.error_) return core.JSValue.undefinedValue();
    if (object.errorStack()) |stack| return stack.dup();
    if (object.errorStackSites()) |sites| {
        const stack = try formatCapturedErrorStackValue(ctx, output, global, this_value, sites, object.errorStackSiteCount());
        errdefer stack.free(ctx.runtime);
        try object.setErrorStack(ctx.runtime, stack);
        return stack;
    }
    return buildErrorStackValue(ctx, output, global, this_value, null);
}

pub fn qjsErrorStackSetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const receiver = objectFromValue(this_value) orelse return error.TypeError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!value.isString()) return error.TypeError;

    const home_global = objectRealmGlobal(function_object) orelse global;
    if (constructorPrototypeFromGlobal(ctx.runtime, home_global, "Error")) |error_proto| {
        if (sameObjectIdentity(this_value, error_proto.value())) return error.TypeError;
    }

    const stack_key = try ctx.runtime.internAtom("stack");
    defer ctx.runtime.atoms.free(stack_key);
    const desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, receiver, stack_key, caller_function, caller_frame);
    defer if (desc) |item| item.destroy(ctx.runtime);

    if (desc == null) {
        const create_desc = core.Descriptor.data(value, true, true, true);
        const ok = if (receiver.proxyTarget() != null)
            try proxyDefineOwnProperty(ctx, output, global, receiver, stack_key, create_desc, caller_function, caller_frame)
        else blk: {
            receiver.defineOwnProperty(ctx.runtime, stack_key, create_desc) catch |err| switch (err) {
                error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => break :blk false,
                error.InvalidLength => return error.RangeError,
                else => return err,
            };
            break :blk true;
        };
        if (!ok) return error.TypeError;
        return core.JSValue.undefinedValue();
    }

    const own_desc = desc.?;
    if (own_desc.kind == .accessor and sameObjectIdentity(own_desc.setter, function_object.value()) and isErrorStackSetterValue(own_desc.setter)) {
        if (try proxySetTrapForErrorStackSetter(ctx, output, global, this_value, receiver, stack_key, value, caller_function, caller_frame)) {
            return core.JSValue.undefinedValue();
        }
        try defineErrorStackDataProperty(ctx, output, global, receiver, stack_key, core.Descriptor.data(value, true, true, true), caller_function, caller_frame);
        return core.JSValue.undefinedValue();
    }

    if (receiver.proxyTarget() != null) {
        const ok = try proxySetValueProperty(ctx, output, global, this_value, receiver, stack_key, value, caller_function, caller_frame);
        if (!ok) return error.TypeError;
        return core.JSValue.undefinedValue();
    }

    switch (own_desc.kind) {
        .accessor => {
            if (own_desc.setter.isUndefined()) return error.TypeError;
            const result = try callValueOrBytecode(ctx, output, global, this_value, own_desc.setter, &.{value}, caller_function, caller_frame);
            result.free(ctx.runtime);
            return core.JSValue.undefinedValue();
        },
        .data, .generic => {
            if (own_desc.kind == .data and own_desc.writable == false) return error.TypeError;
            try defineErrorStackDataProperty(ctx, output, global, receiver, stack_key, core.Descriptor{ .kind = .data, .value = value, .value_present = true }, caller_function, caller_frame);
            return core.JSValue.undefinedValue();
        },
    }
}

pub fn isErrorStackSetterValue(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionId()) orelse return false;
    return native_ref.domain == .error_object and native_ref.id == @intFromEnum(builtins.error_.PrototypeMethod.stack_setter);
}

pub fn throwFunctionRealmTypeError(ctx: *core.JSContext, global: *core.Object, function_object: *core.Object) !core.JSValue {
    const error_global = objectRealmGlobal(function_object) orelse global;
    const error_value = try createNamedError(ctx.runtime, error_global, "TypeError", "not a function");
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

pub fn toNumberForDateMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (value.isObject()) {
        const primitive = try toPrimitiveForNumber(ctx, output, global, value);
        defer primitive.free(ctx.runtime);
        return value_ops.toNumberValue(ctx.runtime, primitive);
    }
    _ = caller_function;
    _ = caller_frame;
    return value_ops.toNumberValue(ctx.runtime, value);
}

pub fn constructValueOrBytecode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructValueOrBytecodeWithNewTarget(ctx, output, global, func, args, caller_function, caller_frame, func);
}

pub fn constructValueOrBytecodeWithNewTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) HostError!core.JSValue {
    if (objectFromValue(func)) |object| {
        if (object.proxyTarget() != null) {
            return constructProxy(ctx, output, global, func, object, args, caller_function, caller_frame, new_target);
        }
    }
    if (callableObjectFromValue(func)) |function_object| {
        if (function_object.class_id == core.class.ids.bound_function) {
            const target = function_object.boundTarget() orelse return error.TypeError;
            var combined = try boundFunctionArgs(ctx.runtime, function_object, args);
            defer freeArgs(ctx.runtime, combined);
            var combined_root = ValueSliceRoot{};
            combined_root.init(ctx.runtime, &combined);
            defer combined_root.deinit();
            const next_new_target = if (builtins.object.sameValue(func, new_target)) target else new_target;
            return constructValueOrBytecodeWithNewTarget(ctx, output, global, target, combined, caller_function, caller_frame, next_new_target);
        }
        if (function_object.typedArrayElementSize() != 0 and function_object.typedArrayKind() != 0) {
            if (!builtins.object.sameValue(new_target, func)) {
                const name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
                defer ctx.runtime.memory.allocator.free(name);
                if (try constructBuiltinSuperConstructor(ctx, output, global, func, name, args, caller_function, caller_frame, new_target)) |constructed| {
                    return constructed;
                }
            }
            if (qjsTypedArrayConstructVm(ctx, output, global, func, function_object, args, caller_function, caller_frame) catch |err| switch (err) {
                error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid array index"),
                else => return err,
            }) |value| return value;
            return construct_mod.constructValue(ctx.runtime, func, args, &.{});
        }
        if (builtins.date.isConstructorRecord(function_object)) {
            const prototype = try reflectConstructPrototypeVm(ctx, output, global, "Date", new_target, caller_function, caller_frame);
            return date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype, args);
        }
        if (try constructArrayBufferNativeRecord(ctx, output, global, func, function_object, args, new_target)) |constructed| {
            return constructed;
        }
        const dispatch_name = call_mod.nativeFunctionDispatchNameRef(ctx.runtime, function_object);
        defer if (dispatch_name) |dispatch| dispatch.name_value.free(ctx.runtime);
        var owned_name: ?[]u8 = null;
        defer if (owned_name) |name_bytes| ctx.runtime.memory.allocator.free(name_bytes);
        const name = if (dispatch_name) |dispatch|
            dispatch.name
        else blk: {
            owned_name = try call_mod.nativeFunctionNameForVm(ctx.runtime, function_object);
            break :blk owned_name.?;
        };
        if (isBuiltinConstructorName(name) and !builtins.object.sameValue(new_target, func)) {
            if (try constructBuiltinSuperConstructor(ctx, output, global, func, name, args, caller_function, caller_frame, new_target)) |constructed| {
                return constructed;
            }
        }
        if (std.mem.eql(u8, name, "Function")) return constructFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "AsyncFunction")) return constructAsyncFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "GeneratorFunction")) return constructGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "AsyncGeneratorFunction")) return constructAsyncGeneratorFunctionFromSource(ctx, output, global, func, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "Worker")) return qjsWorkerFunctionCall(ctx, output, global, args);
        if (qjsTypedArrayConstructorName(name)) {
            if (try qjsTypedArrayConstructFromIterable(ctx, output, global, func, args, caller_function, caller_frame)) |value| return value;
        }
        if (std.mem.eql(u8, name, "Number")) {
            const primitive = try qjsNumberFunctionCall(ctx, output, global, args);
            defer primitive.free(ctx.runtime);
            return construct_mod.constructValue(ctx.runtime, func, &.{primitive}, &.{});
        }
        if (std.mem.eql(u8, name, "String")) {
            const prototype = try constructorPrototypeObject(ctx.runtime, new_target);
            return qjsStringConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "Date")) {
            const prototype = try reflectConstructPrototypeVm(ctx, output, global, "Date", new_target, caller_function, caller_frame);
            if (args.len == 0) return date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype, args);

            if (args.len == 1) {
                if (objectFromValue(args[0])) |object| {
                    if (object.class_id == core.class.ids.date) {
                        const time_value = try builtins.date.methodCall(ctx.runtime, args[0], 1);
                        defer time_value.free(ctx.runtime);
                        return date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype, &.{time_value});
                    }

                    const primitive = try toPrimitiveForAddition(ctx, output, global, args[0]);
                    defer primitive.free(ctx.runtime);
                    if (primitive.isString()) return date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype, &.{primitive});
                    const number = try value_ops.toNumberValue(ctx.runtime, primitive);
                    defer number.free(ctx.runtime);
                    return date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype, &.{number});
                }

                if (args[0].isString()) return date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype, args);
                const number = try value_ops.toNumberValue(ctx.runtime, args[0]);
                defer number.free(ctx.runtime);
                return date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype, &.{number});
            }

            var coerced_args: [7]core.JSValue = undefined;
            var coerced_len: usize = 0;
            defer {
                for (coerced_args[0..coerced_len]) |value| value.free(ctx.runtime);
            }
            while (coerced_len < args.len and coerced_len < coerced_args.len) : (coerced_len += 1) {
                coerced_args[coerced_len] = try toNumberForDateMethod(ctx, output, global, args[coerced_len], caller_function, caller_frame);
            }
            return date_vm.qjsDateConstructWithPrototype(ctx, output, global, prototype, coerced_args[0..coerced_len]);
        }
        if (std.mem.eql(u8, name, "Array")) {
            const prototype = try constructorPrototypeObject(ctx.runtime, new_target);
            return builtins.array.constructConstructorWithPrototype(ctx.runtime, args, prototype) catch |err| switch (err) {
                error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid array length"),
                else => err,
            };
        }
        if (std.mem.eql(u8, name, "Promise")) return qjsPromiseConstruct(ctx, output, global, new_target, args, caller_function, caller_frame);
        if (std.mem.eql(u8, name, "DisposableStack")) {
            const prototype = try reflectConstructPrototypeVm(ctx, output, global, "DisposableStack", new_target, caller_function, caller_frame);
            return try qjsDisposableStackConstructWithPrototype(ctx, global, prototype);
        }
        if (std.mem.eql(u8, name, "AsyncDisposableStack")) {
            const prototype = try reflectConstructPrototypeVm(ctx, output, global, "AsyncDisposableStack", new_target, caller_function, caller_frame);
            return try qjsAsyncDisposableStackConstructWithPrototype(ctx, global, prototype);
        }
        if (std.mem.eql(u8, name, "RegExp")) return qjsRegExpConstructCall(ctx, output, global, new_target, args, caller_function, caller_frame);
        if (builtins.collection.constructorId(name)) |kind| return constructCollectionFromVm(ctx, output, global, func, kind, args);
        if (std.mem.eql(u8, name, "ArrayBuffer") or std.mem.eql(u8, name, "SharedArrayBuffer")) {
            const prototype = try constructorPrototypeObject(ctx.runtime, new_target);
            return qjsArrayBufferConstructWithPrototype(ctx, output, global, args, prototype, std.mem.eql(u8, name, "SharedArrayBuffer"));
        }
        if (std.mem.eql(u8, name, "DataView")) {
            const coerced = try qjsDataViewConstructorArgs(ctx, output, global, args);
            const prototype = try constructorPrototypeObject(ctx.runtime, new_target);
            return try qjsDataViewConstructWithPrototype(ctx.runtime, args[0], coerced, prototype);
        }
        if (std.mem.eql(u8, name, "DOMException")) {
            const prototype = try constructorPrototypeObject(ctx.runtime, new_target);
            return try construct_mod.constructDOMExceptionObject(ctx.runtime, prototype, args);
        }
        if (std.mem.eql(u8, name, "AggregateError")) {
            const prototype = try constructorPrototypeObject(ctx.runtime, new_target);
            const constructor_global = objectRealmGlobal(function_object) orelse global;
            return try qjsAggregateErrorConstructWithPrototype(ctx, output, constructor_global, prototype, args, caller_function, caller_frame);
        }
        if (std.mem.eql(u8, name, "SuppressedError")) {
            const prototype = try constructorPrototypeObject(ctx.runtime, new_target);
            return try qjsSuppressedErrorConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
        }
        if (isErrorConstructorName(name)) {
            const prototype = try constructorPrototypeObject(ctx.runtime, new_target);
            return try qjsErrorConstructWithPrototype(ctx, output, global, name, prototype, args, caller_function, caller_frame);
        }
        if (function_object.hostFunctionKindSlot().* == core.host_function.ids.external_host) {
            return constructExternalHostFunction(ctx, output, global, function_object, args, caller_function, caller_frame, new_target);
        }
        if (function_object.class_id == core.class.ids.c_function and !isBuiltinConstructorName(name)) return error.TypeError;
    }
    if (func.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(func) orelse return error.TypeError;
        if (fb.is_arrow_function or !fb.has_prototype or fb.func_kind == .generator or fb.func_kind == .async_generator) return error.TypeError;
        const instance = try createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);
        errdefer instance.free(ctx.runtime);
        if (!fb.is_derived_class_constructor) {
            try initializeClassInstanceElements(ctx, output, global, func, instance, fb, caller_function, caller_frame);
        }
        const initial_this = if (fb.is_derived_class_constructor) core.JSValue.uninitialized() else instance;
        const constructor_this = if (fb.is_derived_class_constructor) instance else core.JSValue.undefinedValue();
        const result = try callFunctionBytecodeConstruct(ctx, func, func, initial_this, args, &.{}, output, global, &.{}, &.{}, new_target, constructor_this);
        defer result.free(ctx.runtime);
        if (result.isObject()) {
            instance.free(ctx.runtime);
            return result.dup();
        }
        return instance;
    }
    if (functionObjectFromValue(func)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (fb.is_class_constructor) {
            // Special handling for class constructors (published via top-level script/module binding or direct define_class).
            // This is the VM alignment fix for the "not a constructor" bug in top-level class decl in plain .js scripts
            // (the functionObjectFromValue path was not recognizing is_class_constructor and taking the ordinary path,
            // which rejected class ctors or used wrong initial_this for derived/fields init).
            const instance = try createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);
            errdefer instance.free(ctx.runtime);
            if (!fb.is_derived_class_constructor) {
                try initializeClassInstanceElements(ctx, output, global, func, instance, fb, caller_function, caller_frame);
            }
            const function_global = objectRealmGlobal(function_object) orelse global;
            const initial_this = if (fb.is_derived_class_constructor) core.JSValue.uninitialized() else instance;
            const constructor_this = if (fb.is_derived_class_constructor) instance else core.JSValue.undefinedValue();
            const result = try callFunctionBytecodeConstruct(ctx, function_value, func, initial_this, args, function_object.functionCapturesSlot().*, output, function_global, function_object.functionEvalLocalNamesSlot().*, function_object.functionEvalLocalRefsSlot().*, new_target, constructor_this);
            defer result.free(ctx.runtime);
            if (result.isObject()) {
                instance.free(ctx.runtime);
                return result.dup();
            }
            return instance;
        }
        if (fb.is_arrow_function or !fb.has_prototype or fb.func_kind == .generator or fb.func_kind == .async_generator) return error.TypeError;
        const instance = try createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);
        errdefer instance.free(ctx.runtime);
        if (!fb.is_derived_class_constructor) {
            try initializeClassInstanceElements(ctx, output, global, func, instance, fb, caller_function, caller_frame);
        }
        const function_global = objectRealmGlobal(function_object) orelse global;
        const initial_this = if (fb.is_derived_class_constructor) core.JSValue.uninitialized() else instance;
        const constructor_this = if (fb.is_derived_class_constructor) instance else core.JSValue.undefinedValue();
        const result = try callFunctionBytecodeConstruct(ctx, function_value, func, initial_this, args, function_object.functionCapturesSlot().*, output, function_global, function_object.functionEvalLocalNamesSlot().*, function_object.functionEvalLocalRefsSlot().*, new_target, constructor_this);
        defer result.free(ctx.runtime);
        if (result.isObject()) {
            instance.free(ctx.runtime);
            return result.dup();
        }
        return instance;
    }
    if (objectFromValue(func)) |object| {
        if (object.class_id == core.class.ids.object and object.proxyTarget() == null) {
            return throwTypeErrorMessage(ctx, global, "not a constructor");
        }
    }
    return construct_mod.constructValue(ctx.runtime, func, args, &.{});
}

fn constructExternalHostFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target: core.JSValue,
) !core.JSValue {
    if (!function_object.hasOwnProperty(core.atom.ids.prototype)) return error.TypeError;
    const instance = try createConstructorInstance(ctx, output, global, new_target, caller_function, caller_frame);
    var instance_owned = true;
    errdefer if (instance_owned) instance.free(ctx.runtime);

    const result = (try call_mod.callHostFunctionObjectForVm(ctx, output, global, function_object, instance, args)) orelse return error.TypeError;
    defer result.free(ctx.runtime);
    if (result.isObject()) {
        instance.free(ctx.runtime);
        instance_owned = false;
        return result.dup();
    }
    instance_owned = false;
    return instance;
}

pub fn globalHostOutputAutoInit(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) bool {
    if (global.exotic != null) return false;
    for (global.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return false;
        return switch (entry.slot) {
            .auto_init => |info| info.host_function_kind == core.host_function.ids.output or
                (info.host_function_kind == core.host_function.ids.external_host and
                    call_mod.isOutputExternalHostFunctionId(rt, info.external_host_function_id)),
            .data, .accessor, .deleted => false,
        };
    }
    return false;
}

pub const DataViewConstructorArgs = struct {
    byte_offset: usize,
    view_length: ?usize,
    has_offset: bool,
};

pub fn qjsDataViewConstructorArgs(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !DataViewConstructorArgs {
    if (args.len < 1) return error.TypeError;
    try builtins.buffer.dataViewRequireArrayBuffer(args[0]);
    const byte_offset = if (args.len >= 2)
        try qjsTypedArrayConstructToIndex(ctx, output, global, args[1])
    else
        @as(usize, 0);
    const view_length = if (args.len >= 3 and !args[2].isUndefined())
        try qjsTypedArrayConstructToIndex(ctx, output, global, args[2])
    else
        null;
    try builtins.buffer.dataViewValidateConstructorRange(ctx.runtime, args[0], byte_offset, view_length);
    return .{
        .byte_offset = byte_offset,
        .view_length = view_length,
        .has_offset = args.len >= 2,
    };
}

pub fn initializeClassInstanceElements(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    instance: core.JSValue,
    fb: *const bytecode.FunctionBytecode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const constructor_object = objectFromValue(constructor_value);
    const remap_object = if (constructor_object) |object| object.functionHomeObjectSlot().* else null;
    if (remap_object) |home_object| {
        const instance_object = try property_ops.expectObject(instance);
        try initializeClassPrivateMethods(ctx.runtime, instance_object, home_object);
    }
    try initializeClassInstanceFields(ctx.runtime, instance, fb.class_instance_fields, remap_object);
    const init_function = if (constructor_object) |object|
        object.functionClassFieldsInitSlot().*
    else
        fb.class_fields_init;
    if (init_function) |initializer| {
        const result = try callValueOrBytecode(ctx, output, global, instance, initializer, &.{}, caller_function, caller_frame);
        result.free(ctx.runtime);
    }
}

pub fn initializeCurrentConstructorClassInstanceElements(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
) !void {
    if (caller_frame.this_value.isUninitialized()) return;
    if (functionObjectFromValue(caller_frame.current_function)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return;
        const fb = functionBytecodeFromValue(function_value) orelse return;
        try initializeClassInstanceElements(ctx, output, global, caller_frame.current_function, caller_frame.this_value, fb, caller_function, caller_frame);
        return;
    }
    if (functionBytecodeFromValue(caller_frame.current_function)) |fb| {
        try initializeClassInstanceElements(ctx, output, global, caller_frame.current_function, caller_frame.this_value, fb, caller_function, caller_frame);
    }
}

pub fn initializeClassPrivateMethods(rt: *core.JSRuntime, instance: *core.Object, home_object: *core.Object) !void {
    for (home_object.properties) |entry| {
        if (rt.atoms.kind(entry.atom_id) != .private) continue;
        if (instance.hasOwnProperty(entry.atom_id)) return error.TypeError;
        if (home_object.getOwnProperty(entry.atom_id)) |desc| {
            defer desc.destroy(rt);
            instance.defineOwnProperty(rt, entry.atom_id, desc) catch |err| switch (err) {
                error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                else => return err,
            };
        }
    }
}

pub fn initializeClassInstanceFields(rt: *core.JSRuntime, instance: core.JSValue, fields: []const core.Atom, remap_object: ?*const core.Object) !void {
    if (fields.len == 0) return;
    const object = try property_ops.expectObject(instance);
    for (fields) |atom_id| {
        const effective_atom = remapPrivateAtomForOperation(rt, null, remap_object, atom_id);
        try defineClassFieldDataProperty(rt, object, effective_atom, core.JSValue.undefinedValue());
    }
}

pub fn qjsDataViewAccessor(ctx: *core.JSContext, receiver: core.JSValue, accessor: []const u8) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.dataview) return error.TypeError;
    if (std.mem.eql(u8, accessor, "buffer")) {
        return (object.typedArrayBuffer() orelse return error.TypeError).dup();
    }
    if (std.mem.eql(u8, accessor, "byteLength")) {
        return core.JSValue.int32(@intCast(try builtins.buffer.dataViewByteLength(ctx.runtime, object)));
    }
    if (std.mem.eql(u8, accessor, "byteOffset")) {
        return core.JSValue.int32(@intCast(try builtins.buffer.dataViewByteOffset(ctx.runtime, object)));
    }
    return error.TypeError;
}

pub fn qjsDataViewGet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    try builtins.buffer.dataViewRequire(receiver);
    const index_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const index = try qjsTypedArrayConstructToIndex(ctx, output, global, index_arg);
    const little_endian = args.len >= 2 and value_ops.isTruthy(args[1]);
    const call_args = [_]core.JSValue{ lengthIndexValue(index), core.JSValue.boolean(little_endian) };
    return builtins.buffer.dataViewGet(ctx.runtime, receiver, method_id, call_args[0..]);
}

pub fn qjsDataViewSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    try builtins.buffer.dataViewRejectImmutable(ctx.runtime, receiver);
    const index_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const index = try qjsTypedArrayConstructToIndex(ctx, output, global, index_arg);
    const value_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const coerced_value = try qjsDataViewSetCoerceValue(ctx, output, global, method_id, value_arg);
    defer coerced_value.free(ctx.runtime);
    const little_endian = args.len >= 3 and value_ops.isTruthy(args[2]);
    const call_args = [_]core.JSValue{ lengthIndexValue(index), coerced_value, core.JSValue.boolean(little_endian) };
    return builtins.buffer.dataViewSet(ctx.runtime, receiver, method_id, call_args[0..]);
}

pub fn qjsDataViewSetCoerceValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    method_id: u32,
    value: core.JSValue,
) !core.JSValue {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    errdefer primitive.free(ctx.runtime);
    if (method_id == 9 or method_id == 10) return primitive;
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    primitive.free(ctx.runtime);
    return number_value;
}

pub fn qjsErrorIsError(args: []const core.JSValue) core.JSValue {
    if (args.len < 1) return core.JSValue.boolean(false);
    const object = objectFromValue(args[0]) orelse return core.JSValue.boolean(false);
    return core.JSValue.boolean(object.class_id == core.class.ids.error_);
}

pub fn qjsWeakRefDeref(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.weak_ref) return error.TypeError;
    return object.weakRefDeref(rt);
}

pub fn qjsFinalizationRegistryRegister(ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.finalization_registry) return error.TypeError;
    const target = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const held_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const unregister_token = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    if (!qjsCanBeHeldWeakly(ctx.runtime, target)) return error.TypeError;
    if (builtins.object.sameValue(target, held_value)) return error.TypeError;
    if (!unregister_token.isUndefined() and !qjsCanBeHeldWeakly(ctx.runtime, unregister_token)) return error.TypeError;
    if (builtins.object.sameValue(target, receiver)) return core.JSValue.undefinedValue();
    try qjsFinalizationRegistryAppendCell(ctx.runtime, object, target, held_value, unregister_token);
    return core.JSValue.undefinedValue();
}

pub fn qjsFinalizationRegistryUnregister(ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.finalization_registry) return error.TypeError;
    const token = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!qjsCanBeHeldWeakly(ctx.runtime, token)) return error.TypeError;
    return core.JSValue.boolean(object.unregisterFinalizationRegistryCells(ctx.runtime, token));
}

pub fn qjsFinalizationRegistryAppendCell(
    rt: *core.JSRuntime,
    object: *core.Object,
    target: core.JSValue,
    held_value: core.JSValue,
    unregister_token: core.JSValue,
) !void {
    try object.appendFinalizationRegistryCell(rt, target, held_value, unregister_token);
}

pub fn qjsCanBeHeldWeakly(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (value.isObject()) return true;
    if (value.asSymbolAtom()) |atom_id| {
        return rt.atoms.kind(atom_id) == .symbol and builtins.symbol.registryKey(&rt.atoms, atom_id) == null;
    }
    return false;
}

test "qjsConstructWeakRefWithPrototype roots direct symbol target while creating weak ref" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-qjs-weak-ref-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const weak_ref_value = try qjsConstructWeakRefWithPrototype(rt, core.JSValue.symbol(symbol_atom), null);
    var weak_ref_alive = true;
    defer if (weak_ref_alive) weak_ref_value.free(rt);
    const weak_ref = objectFromValue(weak_ref_value) orelse return error.TypeError;

    const live = weak_ref.weakRefDeref(rt);
    try std.testing.expect(live.same(core.JSValue.symbol(symbol_atom)));
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expect(weak_ref.weakRefDeref(rt).isUndefined());

    weak_ref_value.free(rt);
    weak_ref_alive = false;
}

test "qjsConstructFinalizationRegistryWithPrototype roots function bytecode cleanup while creating registry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-finalization-cleanup-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var cleanup_callback = core.JSValue.functionBytecode(&fb.header);
    var cleanup_callback_alive = true;
    defer if (cleanup_callback_alive) cleanup_callback.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const registry_value = try qjsConstructFinalizationRegistryWithPrototype(rt, cleanup_callback, null);
    var registry_alive = true;
    defer if (registry_alive) registry_value.free(rt);
    const registry = objectFromValue(registry_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = registry.finalizationRegistryCleanupCallback() orelse return error.TypeError;
    try std.testing.expect(stored.same(cleanup_callback));

    registry_value.free(rt);
    registry_alive = false;
    cleanup_callback.free(rt);
    cleanup_callback_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "qjsFinalizationRegistryAppendCell roots direct symbol fields while allocating cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    var registry_alive = true;
    defer if (registry_alive) registry.value().free(rt);
    const target_atom = try rt.atoms.newValueSymbol("gc-finalization-target-symbol");
    const held_atom = try rt.atoms.newValueSymbol("gc-finalization-held-symbol");
    const token_atom = try rt.atoms.newValueSymbol("gc-finalization-token-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try qjsFinalizationRegistryAppendCell(
        rt,
        registry,
        core.JSValue.symbol(target_atom),
        core.JSValue.symbol(held_atom),
        core.JSValue.symbol(token_atom),
    );

    try std.testing.expect(rt.atoms.name(target_atom) != null);
    try std.testing.expect(rt.atoms.name(held_atom) != null);
    try std.testing.expect(rt.atoms.name(token_atom) != null);
    try std.testing.expectEqual(@as(usize, 1), registry.finalizationRegistryCells().len);
    const cell = registry.finalizationRegistryCells()[0];
    try std.testing.expect(cell.held_value.same(core.JSValue.symbol(held_atom)));
    try std.testing.expect(cell.unregister_token.same(core.JSValue.symbol(token_atom)));

    registry.value().free(rt);
    registry_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(target_atom) == null);
    try std.testing.expect(rt.atoms.name(held_atom) == null);
    try std.testing.expect(rt.atoms.name(token_atom) == null);
}

pub fn qjsSymbolFor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const key = if (args.len >= 1)
        try toStringBytesForSymbol(ctx, output, global, args[0], caller_function, caller_frame)
    else
        try ctx.runtime.memory.allocator.dupe(u8, "undefined");
    defer ctx.runtime.memory.allocator.free(key);

    const registered = try std.fmt.allocPrint(ctx.runtime.memory.allocator, "{s}{s}", .{ builtins.symbol.registry_prefix, key });
    defer ctx.runtime.memory.allocator.free(registered);
    const atom_id = try ctx.runtime.atoms.internRegisteredValueSymbol(registered);
    return core.JSValue.symbol(atom_id);
}

pub fn qjsSymbolKeyFor(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const atom_id = value.asSymbolAtom() orelse return error.TypeError;
    const key = builtins.symbol.registryKey(&rt.atoms, atom_id) orelse return core.JSValue.undefinedValue();
    return value_ops.createStringValue(rt, key);
}

pub fn qjsCreateBuiltinFunction(rt: *core.JSRuntime, global: *core.Object, name: []const u8, length: i32) !core.JSValue {
    const function = try builtins.function.nativeFunction(rt, name, length);
    errdefer function.free(rt);
    const object = objectFromValue(function) orelse return error.TypeError;
    try object.setFunctionRealmGlobalPtr(rt, global);
    if (functionPrototypeFromGlobal(rt, global)) |function_proto| {
        try object.setPrototype(rt, function_proto);
    }
    return function;
}

pub fn constructCollectionFromVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    kind: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const prototype = try constructorPrototypeObject(ctx.runtime, constructor);
    return constructCollectionWithPrototypeFromVm(ctx, output, global, kind, args, prototype);
}

pub fn addCollectionEntriesFromIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    collection_value: core.JSValue,
    kind: u32,
    iterable_value: core.JSValue,
    adder: core.JSValue,
) !void {
    const iterator_method = try getIteratorMethod(ctx, output, global, iterable_value);
    defer iterator_method.free(ctx.runtime);
    if (!isCallableValue(iterator_method)) return error.TypeError;
    const iterator_value = try callValueOrBytecode(ctx, output, global, iterable_value, iterator_method, &.{}, null, null);
    defer iterator_value.free(ctx.runtime);
    _ = try property_ops.expectObject(iterator_value);

    while (true) {
        const step = iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
        };
        defer step.value.free(ctx.runtime);
        if (step.done) return;

        if (kind == 1 or kind == 3) {
            const entry = property_ops.expectObject(step.value) catch {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, error.TypeError, null, null);
            };
            const key = getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(0), null, null) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
            defer key.free(ctx.runtime);
            const value = getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(1), null, null) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
            defer value.free(ctx.runtime);
            callCollectionAdderFromVm(ctx, output, global, collection_value, adder, &.{ key, value }) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
        } else {
            callCollectionAdderFromVm(ctx, output, global, collection_value, adder, &.{step.value}) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
        }
    }
}

pub fn callCollectionAdderFromVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    collection_value: core.JSValue,
    adder: core.JSValue,
    args: []const core.JSValue,
) !void {
    const out = try callValueOrBytecode(ctx, output, global, collection_value, adder, args, null, null);
    out.free(ctx.runtime);
}

pub fn closeIteratorFromVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    try closeIteratorFromVmImpl(ctx, output, global, iterator_value);
}

pub fn closeIteratorFromVmImpl(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, iterator_value, return_key, null, null);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) return;
    if (!isCallableValue(return_method)) return error.TypeError;
    const out = try callValueOrBytecode(ctx, output, global, iterator_value, return_method, &.{}, null, null);
    defer out.free(ctx.runtime);
    if (!out.isObject()) return error.TypeError;
}

pub fn isBuiltinConstructorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Object") or
        std.mem.eql(u8, name, "Function") or
        std.mem.eql(u8, name, "AsyncFunction") or
        std.mem.eql(u8, name, "GeneratorFunction") or
        std.mem.eql(u8, name, "AsyncGeneratorFunction") or
        std.mem.eql(u8, name, "Array") or
        std.mem.eql(u8, name, "String") or
        std.mem.eql(u8, name, "Number") or
        std.mem.eql(u8, name, "Boolean") or
        std.mem.eql(u8, name, "Symbol") or
        std.mem.eql(u8, name, "BigInt") or
        std.mem.eql(u8, name, "Date") or
        std.mem.eql(u8, name, "RegExp") or
        builtins.error_names.isErrorConstructorName(name) or
        std.mem.eql(u8, name, "Iterator") or
        std.mem.eql(u8, name, "DisposableStack") or
        std.mem.eql(u8, name, "AsyncDisposableStack") or
        std.mem.eql(u8, name, "Promise") or
        std.mem.eql(u8, name, "Map") or
        std.mem.eql(u8, name, "Set") or
        std.mem.eql(u8, name, "WeakMap") or
        std.mem.eql(u8, name, "WeakSet") or
        std.mem.eql(u8, name, "WeakRef") or
        std.mem.eql(u8, name, "ArrayBuffer") or
        std.mem.eql(u8, name, "SharedArrayBuffer") or
        std.mem.eql(u8, name, "FinalizationRegistry") or
        std.mem.eql(u8, name, "DataView") or
        std.mem.eql(u8, name, "TypedArray") or
        builtins.typed_array_names.isConcrete(name) or
        std.mem.eql(u8, name, "Proxy");
}

pub fn createConstructorInstance(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "Object", new_target, caller_function, caller_frame);
    const instance = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &instance.header);
    return instance.value();
}

pub fn constructFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructDynamicFunctionFromSource(ctx, output, global, constructor, constructor, args, .normal, caller_function, caller_frame);
}

pub fn constructGeneratorFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructDynamicFunctionFromSource(ctx, output, global, constructor, constructor, args, .generator, caller_function, caller_frame);
}

pub const DynamicFunctionKind = enum {
    normal,
    async_function,
    generator,
    async_generator,
};

pub fn dynamicFunctionKindFromName(name: []const u8) ?DynamicFunctionKind {
    if (std.mem.eql(u8, name, "Function")) return .normal;
    if (std.mem.eql(u8, name, "AsyncFunction")) return .async_function;
    if (std.mem.eql(u8, name, "GeneratorFunction")) return .generator;
    if (std.mem.eql(u8, name, "AsyncGeneratorFunction")) return .async_generator;
    return null;
}

pub fn constructDynamicFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    new_target: core.JSValue,
    args: []const core.JSValue,
    kind: DynamicFunctionKind,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var params = std.ArrayList(u8).empty;
    defer params.deinit(ctx.runtime.memory.allocator);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(ctx.runtime.memory.allocator);

    if (args.len > 0) {
        for (args[0 .. args.len - 1], 0..) |arg, idx| {
            if (idx != 0) try params.append(ctx.runtime.memory.allocator, ',');
            const string_value = try toStringForAnnexB(ctx, output, global, arg, caller_function, caller_frame);
            defer string_value.free(ctx.runtime);
            try appendSourceStringUtf8(ctx.runtime, &params, string_value);
        }
        const body_value = try toStringForAnnexB(ctx, output, global, args[args.len - 1], caller_function, caller_frame);
        defer body_value.free(ctx.runtime);
        try appendSourceStringUtf8(ctx.runtime, &body, body_value);
    }
    const function_global = dynamicFunctionRealmGlobal(constructor) orelse global;
    if ((kind == .async_function or kind == .async_generator) and try parameterSourceContainsAwait(ctx.runtime, params.items)) {
        return throwSyntaxErrorMessage(ctx, function_global, "invalid syntax");
    }

    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    const prefix = switch (kind) {
        .normal => "(function anonymous(",
        .async_function => "(async function anonymous(",
        .generator => "(function* anonymous(",
        .async_generator => "(async function* anonymous(",
    };
    try source.appendSlice(ctx.runtime.memory.allocator, prefix);
    try source.appendSlice(ctx.runtime.memory.allocator, params.items);
    try source.appendSlice(ctx.runtime.memory.allocator, "\n) {\n");
    if (if (kind == .normal) nativeTypedArraySubclassBase(body.items) else null) |base_name| {
        try source.appendSlice(ctx.runtime.memory.allocator, "return ");
        try source.appendSlice(ctx.runtime.memory.allocator, base_name);
        try source.append(ctx.runtime.memory.allocator, ';');
    } else {
        try source.appendSlice(ctx.runtime.memory.allocator, body.items);
    }
    try source.appendSlice(ctx.runtime.memory.allocator, "\n})");

    const filename = switch (kind) {
        .normal => "Function",
        .async_function => "AsyncFunction",
        .generator => "GeneratorFunction",
        .async_generator => "AsyncGeneratorFunction",
    };
    var compiled = try frontend.parser.parse(ctx.runtime, source.items, .{ .mode = .eval_direct, .filename = filename, .strict = false });
    defer compiled.deinit();
    if (compiled.syntax_error != null) return throwSyntaxErrorMessage(ctx, function_global, "invalid syntax");
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    const result = try runWithArgs(ctx, &nested_stack, &compiled.function, function_global.value(), &.{}, &.{}, output, function_global, true, false, false, &.{}, &.{}, &.{}, &.{});
    errdefer result.free(ctx.runtime);
    if (functionObjectFromValue(result)) |function_object| {
        const prototype = try dynamicFunctionNewTargetPrototype(ctx, output, global, new_target, kind, caller_function, caller_frame);
        try function_object.setPrototype(ctx.runtime, prototype);
        clearFunctionEvalCaptures(ctx.runtime, function_object);
        try copyRealmPrototypeKeys(ctx.runtime, constructor, function_object);
        if (function_global != global) {
            try function_object.setOptionalValueSlot(ctx.runtime, function_object.functionRealmGlobalSlot(), function_global.value().dup());
        }
    }
    return result;
}

pub fn dynamicFunctionRealmGlobal(constructor: core.JSValue) ?*core.Object {
    const constructor_object = property_ops.expectObject(constructor) catch return null;
    return objectRealmGlobal(constructor_object);
}

pub fn functionRealmGlobal(object: *core.Object) ?*core.Object {
    if (object.proxyTarget()) |target_value| {
        const target_object = objectFromValue(target_value) orelse return null;
        return functionRealmGlobal(target_object);
    }
    return objectRealmGlobal(object);
}

pub fn clearFunctionEvalCaptures(rt: *core.JSRuntime, function_object: *core.Object) void {
    const old_names = function_object.functionEvalLocalNamesSlot().*;
    const old_refs = function_object.functionEvalLocalRefsSlot().*;
    function_object.functionEvalLocalNamesSlot().* = &.{};
    function_object.functionEvalLocalRefsSlot().* = &.{};
    for (old_names) |atom_id| rt.atoms.free(atom_id);
    if (old_names.len != 0) rt.memory.free(core.Atom, old_names);
    freeValueSlice(rt, old_refs);
}

pub fn qjsAssertThrows(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const expected = try property_ops.expectObject(args[0]);
    const expected_name = try call_mod.nativeFunctionNameForVm(ctx.runtime, expected);
    defer ctx.runtime.memory.allocator.free(expected_name);
    const result = callAssertThrowsCallback(ctx, output, global, args[1], caller_function, caller_frame) catch |err| {
        if (exception_ops.pendingExceptionMatchesError(ctx, err)) {
            if (try consumePendingExceptionIfMatchesConstructor(ctx, expected_name)) {
                return core.JSValue.undefinedValue();
            }
            return error.JSException;
        }
        if (call_mod.errorNameMatchesConstructorForVm(err, expected_name)) {
            ctx.clearException();
            return core.JSValue.undefinedValue();
        }
        return error.JSException;
    };
    defer result.free(ctx.runtime);
    return error.JSException;
}

pub fn callAssertThrowsCallback(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    callback: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const caller = caller_function orelse return callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), callback, &.{}, caller_function, caller_frame);
    const frame = caller_frame orelse return callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), callback, &.{}, caller_function, caller_frame);
    if (functionObjectFromValue(callback)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return error.TypeError;
        var extra_names: []core.Atom = &.{};
        var extra_refs: []core.JSValue = &.{};
        defer {
            for (extra_refs) |value| value.free(ctx.runtime);
            if (extra_names.len != 0) ctx.runtime.memory.free(core.Atom, extra_names);
            if (extra_refs.len != 0) ctx.runtime.memory.free(core.JSValue, extra_refs);
        }
        try collectCallerEvalRefs(ctx, caller, frame, &extra_names, &extra_refs);
        if (extra_names.len == 0 or extra_refs.len == 0) {
            return callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), callback, &.{}, caller_function, caller_frame);
        }
        return callFunctionBytecode(ctx, function_value, callback, core.JSValue.undefinedValue(), &.{}, function_object.functionCapturesSlot().*, output, global, extra_names, extra_refs);
    }
    return callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), callback, &.{}, caller_function, caller_frame);
}

pub fn collectCallerEvalRefs(
    ctx: *core.JSContext,
    caller: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    names_out: *[]core.Atom,
    refs_out: *[]core.JSValue,
) !void {
    const var_ref_count = @min(caller.var_ref_names.len, frame.var_refs.len);
    const local_count = @min(caller.var_names.len, frame.locals.len);
    const total = var_ref_count + local_count;
    if (total == 0) return;

    const names = try ctx.runtime.memory.alloc(core.Atom, total);
    errdefer ctx.runtime.memory.free(core.Atom, names);
    const refs = try ctx.runtime.memory.alloc(core.JSValue, total);
    var rooted_refs: []core.JSValue = refs[0..0];
    var refs_root = ValueSliceRoot{};
    refs_root.init(ctx.runtime, &rooted_refs);
    defer refs_root.deinit();
    var initialized: usize = 0;
    errdefer {
        for (refs[0..initialized]) |*value| {
            value.free(ctx.runtime);
            value.* = core.JSValue.undefinedValue();
        }
        rooted_refs = &.{};
        ctx.runtime.memory.free(core.JSValue, refs);
    }

    for (caller.var_ref_names[0..var_ref_count], 0..) |atom_id, idx| {
        names[initialized] = atom_id;
        refs[initialized] = frame.var_refs[idx].dup();
        initialized += 1;
        rooted_refs = refs[0..initialized];
    }
    for (caller.var_names[0..local_count], 0..) |atom_id, idx| {
        names[initialized] = atom_id;
        refs[initialized] = try ensureVarRefCell(ctx, &frame.locals[idx]);
        initialized += 1;
        rooted_refs = refs[0..initialized];
    }

    names_out.* = names;
    refs_out.* = refs;
}

pub fn simpleNumericArg0Callback(callback: core.JSValue) ?SimpleNumericArg0Bytecode {
    if (callback.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(callback) orelse return null;
        return cachedSimpleNumericArg0Bytecode(fb) orelse simpleNumericArg0Bytecode(fb);
    }
    const function_object = functionObjectFromValue(callback) orelse return null;
    if (function_object.functionCapturesSlot().*.len != 0) return null;
    const function_value = function_object.functionBytecodeSlot().* orelse return null;
    const fb = functionBytecodeFromValue(function_value) orelse return null;
    return cachedSimpleNumericArg0Bytecode(fb) orelse simpleNumericArg0Bytecode(fb);
}

pub const SparseIndexKey = struct {
    atom_id: core.Atom,
    index: usize,
};

pub fn lengthIndexValue(index: usize) core.JSValue {
    if (index <= @as(usize, @intCast(std.math.maxInt(i32)))) return core.JSValue.int32(@intCast(index));
    return core.JSValue.float64(@floatFromInt(index));
}

pub fn valuesStrictEqual(rt: *core.JSRuntime, a: core.JSValue, b: core.JSValue) !bool {
    if (a.isNumber() and b.isNumber()) {
        const av = value_ops.numberValue(a) orelse return false;
        const bv = value_ops.numberValue(b) orelse return false;
        if (std.math.isNan(av) or std.math.isNan(bv)) return false;
        return av == bv;
    }
    if (a.asBool()) |ab| {
        if (b.asBool()) |bb| return ab == bb;
    }
    if (a.isNull() or a.isUndefined()) return a.same(b);
    if (a.isBigInt() and b.isBigInt()) return builtins.object.sameValue(a, b);
    if (a.isString() and b.isString()) {
        if (a.same(b)) return true;
        var a_bytes = std.ArrayList(u8).empty;
        defer a_bytes.deinit(rt.memory.allocator);
        var b_bytes = std.ArrayList(u8).empty;
        defer b_bytes.deinit(rt.memory.allocator);
        try value_ops.appendRawString(rt, &a_bytes, a);
        try value_ops.appendRawString(rt, &b_bytes, b);
        return std.mem.eql(u8, a_bytes.items, b_bytes.items);
    }
    return a.same(b);
}

pub const LengthIndexAtom = struct {
    atom: core.Atom,
    owned: bool,

    pub fn deinit(self: LengthIndexAtom, rt: *core.JSRuntime) void {
        if (self.owned) rt.atoms.free(self.atom);
    }
};

pub fn qjsCollectIteratorValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const iterator = objectFromValue(iterator_value) orelse return error.TypeError;
    const values = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    const values_value = values.value();
    errdefer values_value.free(ctx.runtime);
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;

    var index: u32 = 0;
    while (true) : (index += 1) {
        const next = callValueOrBytecode(ctx, output, global, iterator.value(), next_method, &.{}, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer next.free(ctx.runtime);
        const next_object = objectFromValue(next) orelse {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return error.TypeError;
        };
        const done = getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer done.free(ctx.runtime);
        if (done.asBool() == true) break;
        const item = getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
        defer item.free(ctx.runtime);
        values.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(index), core.Descriptor.data(item, true, true, true)) catch |err| {
            try qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
            return err;
        };
    }
    values.length = index;
    return values_value;
}

pub fn qjsIteratorClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, iterator_value, return_key, caller_function, caller_frame);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) return;
    if (!isCallableValue(return_method)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, iterator_value, return_method, &.{}, caller_function, caller_frame);
    result.free(ctx.runtime);
}

pub const destructuring_iterator_state_kind: u8 = 0xf0;
pub const destructuring_iterator_state_mask: u8 = 0xfc;
pub const destructuring_iterator_done_bit: u8 = 0x01;
pub const destructuring_iterator_closing_bit: u8 = 0x02;

pub fn destructuringIteratorStateFromValue(value: core.JSValue) ?*core.Object {
    const object = property_ops.expectObject(value) catch return null;
    return if (isDestructuringIteratorState(object)) object else null;
}

pub fn isDestructuringIteratorState(object: *core.Object) bool {
    return object.class_id == core.class.ids.iterator_wrap and
        ((object.iteratorKindSlot().*) & destructuring_iterator_state_mask) == destructuring_iterator_state_kind;
}

pub fn createDestructuringIteratorState(rt: *core.JSRuntime, iterator_value: core.JSValue) !*core.Object {
    var owned_iterator_value = iterator_value;
    errdefer owned_iterator_value.free(rt);
    const state = try core.Object.create(rt, core.class.ids.iterator_wrap, null);
    errdefer core.Object.destroyFromHeader(rt, &state.header);
    state.iteratorKindSlot().* = destructuring_iterator_state_kind;
    state.iteratorIndexSlot().* = 0;
    try state.setOptionalValueSlot(rt, state.iteratorTargetSlot(), owned_iterator_value);
    owned_iterator_value = core.JSValue.undefinedValue();
    return state;
}

pub fn destructuringIteratorStateDone(state: *core.Object) bool {
    return ((state.iteratorKindSlot().*) & destructuring_iterator_done_bit) != 0;
}

pub fn setDestructuringIteratorStateDone(state: *core.Object) void {
    state.iteratorKindSlot().* |= destructuring_iterator_done_bit;
}

pub fn destructuringIteratorStateClosing(state: *core.Object) bool {
    return ((state.iteratorKindSlot().*) & destructuring_iterator_closing_bit) != 0;
}

pub fn setDestructuringIteratorStateClosing(state: *core.Object) void {
    state.iteratorKindSlot().* |= destructuring_iterator_closing_bit;
}

pub fn qjsDestructuringGet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const target_index: u32 = @intCast(args[1].asInt32() orelse return error.TypeError);
    if (destructuringIteratorStateFromValue(args[0])) |state| {
        const current_index: u32 = @intCast(state.iteratorIndexSlot().*);
        var index = current_index;
        var value = core.JSValue.undefinedValue();
        var has_value = false;
        while (index <= target_index) : (index += 1) {
            if (has_value) value.free(ctx.runtime);
            const step = destructuringIteratorStep(ctx, output, global, state) catch |err| {
                try clearDestructuringIteratorState(ctx.runtime, state);
                return err;
            };
            value = step.value;
            has_value = true;
            state.iteratorIndexSlot().* = index + 1;
        }
        return value;
    }
    if (args[0].isString()) {
        const atom_id = core.atom.atomFromUInt32(target_index);
        if (try getStringIndexValue(ctx.runtime, args[0], atom_id)) |value| return value;
        return core.JSValue.undefinedValue();
    }
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    if (try arrayUsesDefaultIterator(ctx, output, global, args[0], object)) {
        return object.getProperty(core.atom.atomFromUInt32(target_index));
    }

    return error.TypeError;
}

pub fn qjsDestructuringElide(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const target_index: u32 = @intCast(args[1].asInt32() orelse return error.TypeError);
    if (destructuringIteratorStateFromValue(args[0])) |state| {
        const current_index: u32 = @intCast(state.iteratorIndexSlot().*);
        var index = current_index;
        while (index <= target_index) : (index += 1) {
            const step = destructuringIteratorStep(ctx, output, global, state) catch |err| {
                try clearDestructuringIteratorState(ctx.runtime, state);
                return err;
            };
            state.iteratorIndexSlot().* = index + 1;
            step.value.free(ctx.runtime);
            if (step.done) break;
        }
        return core.JSValue.undefinedValue();
    }
    if (args[0].isString()) return core.JSValue.undefinedValue();
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    if (try arrayUsesDefaultIterator(ctx, output, global, args[0], object)) return core.JSValue.undefinedValue();

    return error.TypeError;
}

pub fn qjsDestructuringRest(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const start_index: u32 = @intCast(args[1].asInt32() orelse return error.TypeError);
    if (destructuringIteratorStateFromValue(args[0])) |state| {
        var current_index: u32 = @intCast(state.iteratorIndexSlot().*);
        while (current_index < start_index) : (current_index += 1) {
            const skipped = destructuringIteratorStep(ctx, output, global, state) catch |err| {
                try clearDestructuringIteratorState(ctx.runtime, state);
                return err;
            };
            state.iteratorIndexSlot().* = current_index + 1;
            skipped.value.free(ctx.runtime);
            if (skipped.done) break;
        }

        const out = try core.Object.createArray(ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
        var out_value = out.value();
        var value = core.JSValue.undefinedValue();
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &out_value },
            .{ .value = &value },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = ctx.runtime.active_value_roots,
            .values = &root_values,
        };
        ctx.runtime.active_value_roots = &root_frame;
        defer ctx.runtime.active_value_roots = root_frame.previous;
        defer value.free(ctx.runtime);

        while (true) {
            const step = destructuringIteratorStep(ctx, output, global, state) catch |err| {
                try clearDestructuringIteratorState(ctx.runtime, state);
                return err;
            };
            value = step.value;
            if (step.done) {
                value.free(ctx.runtime);
                value = core.JSValue.undefinedValue();
                break;
            }
            try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(out.length), core.Descriptor.data(value, true, true, true));
            value.free(ctx.runtime);
            value = core.JSValue.undefinedValue();
            current_index += 1;
            state.iteratorIndexSlot().* = current_index;
        }
        return out_value;
    }
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    if (try arrayUsesDefaultIterator(ctx, output, global, args[0], object)) {
        const out = try core.Object.createArray(ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
        var out_value = out.value();
        var value = core.JSValue.undefinedValue();
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &out_value },
            .{ .value = &value },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = ctx.runtime.active_value_roots,
            .values = &root_values,
        };
        ctx.runtime.active_value_roots = &root_frame;
        defer ctx.runtime.active_value_roots = root_frame.previous;
        defer value.free(ctx.runtime);

        var index = start_index;
        while (index < object.length) : (index += 1) {
            value = object.getProperty(core.atom.atomFromUInt32(index));
            try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(out.length), core.Descriptor.data(value, true, true, true));
            value.free(ctx.runtime);
            value = core.JSValue.undefinedValue();
        }
        return out_value;
    }
    return error.TypeError;
}

pub fn appendOwnedAtom(rt: *core.JSRuntime, keys: *[]core.Atom, atom_id: core.Atom) !void {
    const next = try rt.memory.alloc(core.Atom, keys.*.len + 1);
    errdefer rt.memory.free(core.Atom, next);
    @memcpy(next[0..keys.*.len], keys.*);
    next[keys.*.len] = atom_id;
    const old = keys.*;
    keys.* = next;
    if (old.len != 0) rt.memory.free(core.Atom, old);
}

pub fn qjsDestructuringClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1) return core.JSValue.undefinedValue();
    const state = destructuringIteratorStateFromValue(args[0]) orelse return core.JSValue.undefinedValue();
    const iterator_value = (state.iteratorTargetSlot().*) orelse return core.JSValue.undefinedValue();
    if (destructuringIteratorStateDone(state)) {
        try clearDestructuringIteratorState(ctx.runtime, state);
        return core.JSValue.undefinedValue();
    }
    const iterator = try property_ops.expectObject(iterator_value);
    errdefer clearDestructuringIteratorState(ctx.runtime, state) catch {};
    setDestructuringIteratorStateClosing(state);
    setDestructuringIteratorStateDone(state);
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, iterator.value(), return_key, null, null);
    defer return_method.free(ctx.runtime);
    if (!isCallableValue(return_method)) {
        try clearDestructuringIteratorState(ctx.runtime, state);
        return core.JSValue.undefinedValue();
    }
    const result = try callValueOrBytecode(ctx, output, global, iterator.value(), return_method, &.{}, null, null);
    defer result.free(ctx.runtime);
    if (!result.isObject()) {
        try clearDestructuringIteratorState(ctx.runtime, state);
        return error.TypeError;
    }
    try clearDestructuringIteratorState(ctx.runtime, state);
    return core.JSValue.undefinedValue();
}

pub fn qjsDestructuringRequireIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    if (destructuringIteratorStateFromValue(args[0])) |_| return args[0].dup();

    var iterator_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &iterator_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;
    defer iterator_value.free(ctx.runtime);

    const source = property_ops.expectObject(args[0]) catch {
        const iterator_method = try getIteratorMethod(ctx, output, global, args[0]);
        defer iterator_method.free(ctx.runtime);
        if (!isCallableValue(iterator_method)) return error.TypeError;
        iterator_value = try callValueOrBytecode(ctx, output, global, args[0], iterator_method, &.{}, null, null);
        _ = try property_ops.expectObject(iterator_value);
        try cacheDestructuringIteratorNextMethod(ctx, output, global, iterator_value);
        const state = try createDestructuringIteratorState(ctx.runtime, iterator_value.dup());
        return state.value();
    };
    if (try arrayUsesDefaultIterator(ctx, output, global, args[0], source)) return args[0].dup();
    if (source.class_id == core.class.ids.generator or source.class_id == core.class.ids.async_generator) {
        try cacheDestructuringIteratorNextMethod(ctx, output, global, source.value());
        const state = try createDestructuringIteratorState(ctx.runtime, source.value().dup());
        return state.value();
    }
    const iterator_method = try getIteratorMethod(ctx, output, global, args[0]);
    defer iterator_method.free(ctx.runtime);
    if (!isCallableValue(iterator_method)) return error.TypeError;
    iterator_value = try callValueOrBytecode(ctx, output, global, args[0], iterator_method, &.{}, null, null);
    _ = try property_ops.expectObject(iterator_value);
    try cacheDestructuringIteratorNextMethod(ctx, output, global, iterator_value);
    const state = try createDestructuringIteratorState(ctx.runtime, iterator_value.dup());
    return state.value();
}

pub fn getIteratorMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source_value: core.JSValue,
) !core.JSValue {
    const symbol_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    return getValueProperty(ctx, output, global, source_value, symbol_key, null, null);
}

pub fn iteratorForValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (source_value.isString()) return builtins.string.iterator(ctx.runtime, source_value);
    const source_object = property_ops.expectObject(source_value) catch null;
    if (source_object != null and source_object.?.class_id == core.class.ids.string) return builtins.string.iterator(ctx.runtime, source_value);
    if (source_object != null and
        (source_object.?.class_id == core.class.ids.array_iterator or
            source_object.?.class_id == core.class.ids.string_iterator or
            source_object.?.class_id == core.class.ids.generator or
            source_object.?.class_id == core.class.ids.async_generator))
    {
        return source_value.dup();
    }
    const iterator_method = try getIteratorMethod(ctx, output, global, source_value);
    defer iterator_method.free(ctx.runtime);
    if (!isCallableValue(iterator_method)) return error.TypeError;
    const iterator_value = try callValueOrBytecode(ctx, output, global, source_value, iterator_method, &.{}, caller_function, caller_frame);
    errdefer iterator_value.free(ctx.runtime);
    _ = property_ops.expectObject(iterator_value) catch return error.TypeError;
    try cacheIteratorNextMethod(ctx, output, global, iterator_value);
    return iterator_value;
}

pub fn cacheIteratorNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    try cacheIteratorNextMethodMode(ctx, output, global, iterator_value, true);
}

pub fn cacheDestructuringIteratorNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    try cacheIteratorNextMethodMode(ctx, output, global, iterator_value, false);
}

pub fn cacheIteratorNextMethodMode(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    require_callable: bool,
) !void {
    const iterator = try property_ops.expectObject(iterator_value);
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, iterator_value, next_key, null, null);
    defer next_method.free(ctx.runtime);
    if (require_callable and !isCallableValue(next_method)) return error.TypeError;
    const cached = iterator.cachedIteratorNextSlot();
    try iterator.setOptionalValueSlot(ctx.runtime, cached, next_method.dup());
}

pub const DestructuringIteratorStep = struct {
    value: core.JSValue,
    done: bool,
};

pub const IteratorStepResult = struct {
    result: core.JSValue,
    value: core.JSValue,
    done: bool,
};

pub fn destructuringIteratorStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    state: *core.Object,
) !DestructuringIteratorStep {
    const iterator_value = (state.iteratorTargetSlot().*) orelse
        return .{ .value = core.JSValue.undefinedValue(), .done = true };
    const iterator = try property_ops.expectObject(iterator_value);
    const next_method = if (iterator.cachedIteratorNext()) |stored| stored.dup() else blk: {
        const next_key = try ctx.runtime.internAtom("next");
        defer ctx.runtime.atoms.free(next_key);
        break :blk try getValueProperty(ctx, output, global, iterator_value, next_key, null, null);
    };
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;
    var next_result_value = try callValueOrBytecode(ctx, output, global, iterator_value, next_method, &.{}, null, null);
    defer next_result_value.free(ctx.runtime);
    if (objectFromValue(next_result_value)) |promise| {
        if (promise.class_id == core.class.ids.promise) {
            if (promise.promiseIsRejected()) {
                const reason = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
                _ = ctx.throwValue(reason);
                return error.JSException;
            }
            const fulfilled = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
            next_result_value.free(ctx.runtime);
            next_result_value = fulfilled;
        }
    }
    const next_result = property_ops.expectObject(next_result_value) catch return error.TypeError;
    if (next_result.class_id == core.class.ids.regexp) {
        return .{ .value = core.JSValue.undefinedValue(), .done = false };
    }
    const done_key = core.atom.predefinedId("done", .string).?;
    const done = try getValueProperty(ctx, output, global, next_result.value(), done_key, null, null);
    defer done.free(ctx.runtime);
    if (value_ops.isTruthy(done)) {
        setDestructuringIteratorStateDone(state);
        return .{ .value = core.JSValue.undefinedValue(), .done = true };
    }
    const value_key = core.atom.predefinedId("value", .string).?;
    return .{ .value = try getValueProperty(ctx, output, global, next_result.value(), value_key, null, null), .done = false };
}

pub fn appendIteratorValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    source_value: core.JSValue,
    start_index: i32,
) !i32 {
    const source_object = property_ops.expectObject(source_value) catch null;
    const iterator_value = if (source_object != null and
        (source_object.?.class_id == core.class.ids.generator or source_object.?.class_id == core.class.ids.async_generator))
        source_value.dup()
    else blk: {
        const iterator_method = try getIteratorMethod(ctx, output, global, source_value);
        defer iterator_method.free(ctx.runtime);
        if (!isCallableValue(iterator_method)) return error.TypeError;
        break :blk try callValueOrBytecode(ctx, output, global, source_value, iterator_method, &.{}, null, null);
    };
    defer iterator_value.free(ctx.runtime);
    if (!iterator_value.isObject()) return error.TypeError;
    var index = start_index;
    while (true) {
        const step = try iteratorStepValue(ctx, output, global, iterator_value);
        if (step.done) {
            step.value.free(ctx.runtime);
            break;
        }
        try property_ops.defineDataProperty(ctx.runtime, target, core.atom.atomFromUInt32(@intCast(index)), step.value);
        step.value.free(ctx.runtime);
        index += 1;
    }
    return index;
}

pub fn iteratorStepValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !DestructuringIteratorStep {
    const iterator = try property_ops.expectObject(iterator_value);
    const next_method = if (iterator.cachedIteratorNext()) |stored| stored.dup() else blk: {
        const next_key = try ctx.runtime.internAtom("next");
        defer ctx.runtime.atoms.free(next_key);
        break :blk try getValueProperty(ctx, output, global, iterator_value, next_key, null, null);
    };
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;
    var next_result_value = try callValueOrBytecode(ctx, output, global, iterator_value, next_method, &.{}, null, null);
    defer next_result_value.free(ctx.runtime);
    if (objectFromValue(next_result_value)) |promise| {
        if (promise.class_id == core.class.ids.promise) {
            if (promise.promiseIsRejected()) {
                const reason = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
                _ = ctx.throwValue(reason);
                return error.JSException;
            }
            const fulfilled = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
            next_result_value.free(ctx.runtime);
            next_result_value = fulfilled;
        }
    }
    const next_result = property_ops.expectObject(next_result_value) catch return error.TypeError;
    if (next_result.class_id == core.class.ids.regexp) {
        return .{ .value = core.JSValue.undefinedValue(), .done = false };
    }
    const done_key = core.atom.predefinedId("done", .string).?;
    const done = try getValueProperty(ctx, output, global, next_result.value(), done_key, null, null);
    defer done.free(ctx.runtime);
    if (value_ops.isTruthy(done)) return .{ .value = core.JSValue.undefinedValue(), .done = true };
    const value_key = core.atom.predefinedId("value", .string).?;
    return .{ .value = try getValueProperty(ctx, output, global, next_result.value(), value_key, null, null), .done = false };
}

pub fn iteratorStepResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    next_arg: core.JSValue,
) !IteratorStepResult {
    const iterator = try property_ops.expectObject(iterator_value);
    const next_method = if (iterator.cachedIteratorNext()) |stored| stored.dup() else blk: {
        const next_key = try ctx.runtime.internAtom("next");
        defer ctx.runtime.atoms.free(next_key);
        break :blk try getValueProperty(ctx, output, global, iterator_value, next_key, null, null);
    };
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;
    const next_result_value = try callValueOrBytecode(ctx, output, global, iterator_value, next_method, &.{next_arg}, null, null);
    errdefer next_result_value.free(ctx.runtime);
    const next_result = property_ops.expectObject(next_result_value) catch return error.TypeError;
    const done_key = core.atom.predefinedId("done", .string).?;
    const done = try getValueProperty(ctx, output, global, next_result.value(), done_key, null, null);
    defer done.free(ctx.runtime);
    const is_done = valueTruthy(done);
    const value = if (is_done) blk: {
        const value_key = core.atom.predefinedId("value", .string).?;
        break :blk try getValueProperty(ctx, output, global, next_result.value(), value_key, null, null);
    } else core.JSValue.undefinedValue();
    errdefer value.free(ctx.runtime);
    return .{ .result = next_result_value, .value = value, .done = is_done };
}

pub fn clearDestructuringIteratorState(rt: *core.JSRuntime, state: *core.Object) !void {
    if (!isDestructuringIteratorState(state)) return;
    state.clearIteratorTarget(rt);
    state.iteratorIndexSlot().* = 0;
    state.iteratorKindSlot().* = 0;
}

pub fn isCallableValue(value: core.JSValue) bool {
    return value.isFunctionBytecode() or functionObjectFromValue(value) != null or callableObjectFromValue(value) != null or proxyTargetIsCallable(value);
}

pub fn qjsReflectCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const reflect_mod = builtins.reflect_proxy;
    return switch (id) {
        @intFromEnum(reflect_mod.StaticMethod.define_property) => (try qjsDefinePropertyWithKind(ctx, output, global, args, 2, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.get_own_property_descriptor) => (try qjsReflectGetOwnPropertyDescriptorCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.delete_property) => (try qjsReflectDeletePropertyCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.get) => (try qjsReflectGetCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.get_prototype_of) => (try qjsReflectGetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.set) => (try qjsReflectSetCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.set_prototype_of) => (try qjsReflectSetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.is_extensible) => (try qjsReflectIsExtensibleCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.prevent_extensions) => (try qjsReflectPreventExtensionsCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.has) => (try qjsReflectHasCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.own_keys) => (try qjsReflectOwnKeysCall(ctx, output, global, args)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.construct) => (try qjsReflectConstructCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(reflect_mod.StaticMethod.apply) => try qjsReflectApplyCall(ctx, output, global, args, caller_function, caller_frame),
        else => error.TypeError,
    };
}

pub const AtomicsReadModifyOp = enum {
    add,
    @"and",
    compareExchange,
    exchange,
    load,
    @"or",
    sub,
    xor,
};

pub const AtomicsWaiterKey = struct {
    store: ?*core.object.SharedBufferStore = null,
    offset_or_ptr: usize,
};

pub const AtomicsWaiter = struct {
    key: AtomicsWaiterKey,
    notified: bool = false,
    linked: bool = false,
    cond: std.Io.Condition = .init,
    promise: ?core.JSValue = null,
    ctx: ?*core.JSContext = null,
    deadline: ?std.Io.Timestamp = null,
    next: ?*AtomicsWaiter = null,
};

pub var atomics_waiter_mutex: std.Io.Mutex = .init;
pub var atomics_waiters: ?*AtomicsWaiter = null;

pub fn qjsAtomicsCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const atomics_mod = builtins.atomics;
    return switch (id) {
        @intFromEnum(atomics_mod.StaticMethod.is_lock_free) => try qjsAtomicsIsLockFree(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.pause) => try qjsAtomicsPause(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.notify) => try qjsAtomicsNotify(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.wait) => try qjsAtomicsWait(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.wait_async) => try qjsAtomicsWaitAsync(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.store) => try qjsAtomicsStore(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.load) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .load, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.add) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .add, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.@"and") => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .@"and", caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.@"or") => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .@"or", caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.sub) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .sub, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.xor) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .xor, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.exchange) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .exchange, caller_function, caller_frame),
        @intFromEnum(atomics_mod.StaticMethod.compare_exchange) => try qjsAtomicsReadModifyWrite(ctx, output, global, args, .compareExchange, caller_function, caller_frame),
        else => error.TypeError,
    };
}

pub fn qjsAtomicsIsLockFree(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const size_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const size = try toInt32ForAtomics(ctx, output, global, size_value, caller_function, caller_frame);
    return core.JSValue.boolean(size == 1 or size == 2 or size == 4 or size == 8);
}

pub fn qjsAtomicsPause(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    if (args.len >= 1 and !args[0].isUndefined()) {
        if (!args[0].isNumber()) return error.TypeError;
        const number = value_ops.numberValue(args[0]) orelse std.math.nan(f64);
        if (!std.math.isFinite(number) or @trunc(number) != number) return error.TypeError;
    }
    return core.JSValue.undefinedValue();
}

pub fn qjsAtomicsReadModifyWrite(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    atomic_op: AtomicsReadModifyOp,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try atomicsTypedArray(view_value, false);
    if (atomic_op != .load) try builtins.buffer.typedArrayRejectImmutableBuffer(ctx.runtime, view);
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try toIndexForAtomics(ctx, output, global, index_value, caller_function, caller_frame);
    try atomicsValidateIndex(ctx.runtime, view, index);

    const is_bigint = atomicsTypedArrayIsBigInt(view);
    const value_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const replacement_arg = if (args.len >= 4) args[3] else core.JSValue.undefinedValue();
    const operand = if (atomic_op == .load) @as(u64, 0) else if (is_bigint)
        try toBigIntBitsForAtomics(ctx, output, global, value_arg, caller_function, caller_frame)
    else
        try toUint32ForAtomics(ctx, output, global, value_arg, caller_function, caller_frame);
    const replacement = if (atomic_op == .compareExchange) blk: {
        break :blk if (is_bigint)
            try toBigIntBitsForAtomics(ctx, output, global, replacement_arg, caller_function, caller_frame)
        else
            try toUint32ForAtomics(ctx, output, global, replacement_arg, caller_function, caller_frame);
    } else @as(u64, 0);
    try atomicsValidateIndex(ctx.runtime, view, index);

    const bytes = try atomicsElementBytes(view, index);
    const old = atomicsReadBits(view, bytes);
    const next = switch (atomic_op) {
        .load => old,
        .add => old +% operand,
        .@"and" => old & operand,
        .@"or" => old | operand,
        .sub => old -% operand,
        .xor => old ^ operand,
        .exchange => operand,
        .compareExchange => if (old == atomicsMaskBits(view, operand)) replacement else old,
    };
    if (atomic_op != .load) atomicsWriteBits(view, bytes, next);
    return atomicsValueFromBits(ctx.runtime, view, old);
}

pub fn qjsAtomicsStore(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try atomicsTypedArray(view_value, false);
    try builtins.buffer.typedArrayRejectImmutableBuffer(ctx.runtime, view);
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try toIndexForAtomics(ctx, output, global, index_value, caller_function, caller_frame);
    try atomicsValidateIndex(ctx.runtime, view, index);

    const value_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const is_bigint = atomicsTypedArrayIsBigInt(view);
    const stored_value = if (is_bigint)
        try toBigIntValueForAtomics(ctx, output, global, value_arg, caller_function, caller_frame)
    else
        try toIntegerValueForAtomics(ctx, output, global, value_arg, caller_function, caller_frame);
    errdefer stored_value.free(ctx.runtime);
    const bits = if (is_bigint)
        try bigintBitsForAtomics(ctx.runtime, stored_value)
    else
        try uint32FromIntegerValueForAtomics(ctx.runtime, stored_value);
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    atomicsWriteBits(view, bytes, bits);
    return stored_value;
}

pub fn qjsAtomicsNotify(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try atomicsTypedArray(view_value, true);
    const buffer = try atomicsBufferObject(view);
    if (buffer.class_id != core.class.ids.shared_array_buffer and buffer.arrayBufferDetached()) return error.TypeError;
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsValidateAccess(ctx, output, global, view, index_value, caller_function, caller_frame);
    const count = try atomicsNotifyCount(ctx, output, global, args, caller_function, caller_frame);
    if (buffer.class_id != core.class.ids.shared_array_buffer or count == 0) return core.JSValue.int32(0);
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const key = try atomicsWaiterKey(view, bytes);
    return core.JSValue.int32(@intCast(atomicsWakeWaiters(key, count)));
}

pub fn qjsAtomicsWait(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try atomicsTypedArray(view_value, true);
    if ((try atomicsBufferObject(view)).class_id != core.class.ids.shared_array_buffer) return error.TypeError;
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsValidateAccess(ctx, output, global, view, index_value, caller_function, caller_frame);
    const expected_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const expected = if (atomicsTypedArrayIsBigInt(view))
        try toBigIntBitsForAtomics(ctx, output, global, expected_arg, caller_function, caller_frame)
    else
        try toInt32BitsForAtomics(ctx, output, global, expected_arg, caller_function, caller_frame);
    const timeout_arg = if (args.len >= 4) args[3] else core.JSValue.float64(std.math.inf(f64));
    const timeout = try toNumberForAtomics(ctx, output, global, timeout_arg, caller_function, caller_frame);
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const current = atomicsReadBits(view, bytes);
    if (current != atomicsMaskBits(view, expected)) return value_ops.createStringValue(ctx.runtime, "not-equal");
    if (!ctx.runtime.canBlock()) return error.TypeError;
    const wait_ms = atomicsWaitTimeoutMilliseconds(timeout);
    if (wait_ms == 0) return value_ops.createStringValue(ctx.runtime, "timed-out");
    const key = try atomicsWaiterKey(view, bytes);
    return atomicsWaitForNotification(ctx.runtime, key, wait_ms);
}

pub fn atomicsNotifyCount(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    if (args.len < 3 or args[2].isUndefined()) return std.math.maxInt(usize);
    const count_value = try toIntegerValueForAtomics(ctx, output, global, args[2], caller_function, caller_frame);
    defer count_value.free(ctx.runtime);
    const count_number = value_ops.numberValue(count_value) orelse return 0;
    if (std.math.isNan(count_number) or count_number <= 0) return 0;
    if (!std.math.isFinite(count_number)) return std.math.maxInt(usize);
    return @intFromFloat(@min(count_number, @as(f64, @floatFromInt(std.math.maxInt(i32)))));
}

pub fn atomicsWaitTimeoutMilliseconds(timeout: f64) ?i64 {
    if (std.math.isNan(timeout) or !std.math.isFinite(timeout)) return null;
    if (timeout <= 0) return 0;
    return @intFromFloat(@min(timeout, @as(f64, @floatFromInt(std.math.maxInt(i64)))));
}

pub fn atomicsWaiterKey(view: *core.Object, bytes: []const u8) !AtomicsWaiterKey {
    const buffer = try atomicsBufferObject(view);
    if (buffer.class_id == core.class.ids.shared_array_buffer) {
        if (buffer.sharedByteStorageStore()) |store| {
            const base = @intFromPtr(buffer.byteStorage().ptr);
            const ptr = @intFromPtr(bytes.ptr);
            return .{ .store = store, .offset_or_ptr = ptr - base };
        }
    }
    return .{ .offset_or_ptr = @intFromPtr(bytes.ptr) };
}

pub fn atomicsWaiterKeysEqual(a: AtomicsWaiterKey, b: AtomicsWaiterKey) bool {
    return a.store == b.store and a.offset_or_ptr == b.offset_or_ptr;
}

pub fn atomicsRetainWaiterKey(key: AtomicsWaiterKey) void {
    if (key.store) |store| store.retain();
}

pub fn atomicsReleaseWaiterKey(key: *AtomicsWaiterKey) void {
    if (key.store) |store| {
        store.release();
        key.store = null;
    }
}

pub fn atomicsWakeWaiters(key: AtomicsWaiterKey, count: usize) usize {
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);

    var woken: usize = 0;
    var previous: ?*AtomicsWaiter = null;
    var cursor = atomics_waiters;
    while (cursor) |waiter| {
        const next = waiter.next;
        if (!atomicsWaiterKeysEqual(waiter.key, key) or waiter.notified) {
            previous = waiter;
            cursor = next;
            continue;
        }
        waiter.notified = true;
        if (waiter.promise) |promise| {
            atomicsSettleAsyncWaiter(waiter, promise, "ok") catch {};
            if (previous) |prev| {
                prev.next = next;
            } else {
                atomics_waiters = next;
            }
            waiter.linked = false;
            waiter.next = null;
            atomicsDestroyAsyncWaiter(waiter);
        } else {
            waiter.cond.signal(io);
            previous = waiter;
        }
        woken += 1;
        if (woken == count) break;
        cursor = next;
    }
    return woken;
}

pub fn processExpiredAtomicsWaiters(ctx: *core.JSContext) !void {
    const io = atomicsWaiterIo();
    const now = std.Io.Timestamp.now(io, .awake);
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);

    var previous: ?*AtomicsWaiter = null;
    var cursor = atomics_waiters;
    while (cursor) |waiter| {
        const next = waiter.next;
        const expired = waiter.ctx == ctx and waiter.promise != null and waiter.deadline != null and now.nanoseconds >= waiter.deadline.?.nanoseconds;
        if (!expired) {
            previous = waiter;
            cursor = next;
            continue;
        }
        try atomicsSettleAsyncWaiter(waiter, waiter.promise.?, "timed-out");
        if (previous) |prev| {
            prev.next = next;
        } else {
            atomics_waiters = next;
        }
        waiter.linked = false;
        waiter.next = null;
        atomicsDestroyAsyncWaiter(waiter);
        cursor = next;
    }
}

pub fn cleanupAtomicsWaitersForContext(ctx: *core.JSContext) void {
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);

    var previous: ?*AtomicsWaiter = null;
    var cursor = atomics_waiters;
    while (cursor) |waiter| {
        const next = waiter.next;
        if (waiter.ctx != ctx) {
            previous = waiter;
            cursor = next;
            continue;
        }
        if (previous) |prev| {
            prev.next = next;
        } else {
            atomics_waiters = next;
        }
        waiter.linked = false;
        waiter.next = null;
        atomicsDestroyAsyncWaiter(waiter);
        cursor = next;
    }
}

pub fn atomicsWaitForNotification(rt: *core.JSRuntime, key: AtomicsWaiterKey, timeout_ms: ?i64) !core.JSValue {
    atomicsRetainWaiterKey(key);
    var retained_key = key;
    defer atomicsReleaseWaiterKey(&retained_key);

    var waiter = AtomicsWaiter{ .key = retained_key };
    const io = atomicsWaiterIo();
    atomics_waiter_mutex.lockUncancelable(io);
    defer atomics_waiter_mutex.unlock(io);
    atomicsLinkWaiter(&waiter);
    defer atomicsUnlinkWaiter(&waiter);

    if (timeout_ms == null) {
        while (!waiter.notified) waiter.cond.waitUncancelable(io, &atomics_waiter_mutex);
        return value_ops.createStringValue(rt, "ok");
    }

    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(std.Io.Duration.fromMilliseconds(timeout_ms.?));
    while (!waiter.notified) {
        const now = std.Io.Timestamp.now(io, .awake);
        if (now.nanoseconds >= deadline.nanoseconds) break;
        atomics_waiter_mutex.unlock(io);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        atomics_waiter_mutex.lockUncancelable(io);
    }
    return value_ops.createStringValue(rt, if (waiter.notified) "ok" else "timed-out");
}

pub fn atomicsLinkWaiter(waiter: *AtomicsWaiter) void {
    waiter.linked = true;
    waiter.next = null;
    if (atomics_waiters == null) {
        atomics_waiters = waiter;
        return;
    }
    var tail = atomics_waiters.?;
    while (tail.next) |next| tail = next;
    tail.next = waiter;
}

pub fn atomicsUnlinkWaiter(waiter: *AtomicsWaiter) void {
    if (!waiter.linked) return;
    var previous: ?*AtomicsWaiter = null;
    var cursor = atomics_waiters;
    while (cursor) |current| : (cursor = current.next) {
        if (current != waiter) {
            previous = current;
            continue;
        }
        if (previous) |prev| {
            prev.next = current.next;
        } else {
            atomics_waiters = current.next;
        }
        current.next = null;
        current.linked = false;
        return;
    }
}

pub fn atomicsWaiterIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn atomicsValidateAccess(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    index_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    const length = try builtins.buffer.typedArrayLength(ctx.runtime, object);
    const index = try toIndexForAtomics(ctx, output, global, index_value, caller_function, caller_frame);
    if (index >= length) return error.RangeError;
    return index;
}

pub fn atomicsValidateIndex(rt: *core.JSRuntime, object: *core.Object, index: usize) !void {
    const length = try builtins.buffer.typedArrayLength(rt, object);
    if (index >= length) return error.RangeError;
}

pub fn atomicsElementBytes(object: *core.Object, index: usize) ![]u8 {
    const buffer = try atomicsBufferObject(object);
    if (buffer.arrayBufferDetached()) return error.TypeError;
    const offset = object.typedArrayByteOffset() + index * object.typedArrayElementSize();
    if (offset + object.typedArrayElementSize() > buffer.byteStorage().len) return error.RangeError;
    return buffer.byteStorage()[offset..][0..object.typedArrayElementSize()];
}

pub fn atomicsReadBits(object: *core.Object, bytes: []const u8) u64 {
    return switch (object.typedArrayElementSize()) {
        1 => bytes[0],
        2 => std.mem.readInt(u16, bytes[0..2], .little),
        4 => std.mem.readInt(u32, bytes[0..4], .little),
        8 => std.mem.readInt(u64, bytes[0..8], .little),
        else => 0,
    };
}

pub fn atomicsWriteBits(object: *core.Object, bytes: []u8, value: u64) void {
    switch (object.typedArrayElementSize()) {
        1 => bytes[0] = @truncate(value),
        2 => std.mem.writeInt(u16, bytes[0..2], @truncate(value), .little),
        4 => std.mem.writeInt(u32, bytes[0..4], @truncate(value), .little),
        8 => std.mem.writeInt(u64, bytes[0..8], value, .little),
        else => {},
    }
}

pub fn atomicsMaskBits(object: *core.Object, value: u64) u64 {
    return switch (object.typedArrayElementSize()) {
        1 => value & 0xff,
        2 => value & 0xffff,
        4 => value & 0xffff_ffff,
        else => value,
    };
}

pub fn atomicsValueFromBits(rt: *core.JSRuntime, object: *core.Object, bits: u64) !core.JSValue {
    return switch (object.typedArrayKind()) {
        1 => core.JSValue.int32(@as(i8, @bitCast(@as(u8, @truncate(bits))))),
        2 => core.JSValue.int32(@as(u8, @truncate(bits))),
        4 => core.JSValue.int32(@as(i16, @bitCast(@as(u16, @truncate(bits))))),
        5 => core.JSValue.int32(@as(u16, @truncate(bits))),
        6 => core.JSValue.int32(@as(i32, @bitCast(@as(u32, @truncate(bits))))),
        7 => atomicsNumberResult(@floatFromInt(@as(u32, @truncate(bits)))),
        11 => value_ops.createBigIntI128(rt, @as(i64, @bitCast(bits))),
        12 => value_ops.createBigIntI128(rt, @as(i128, bits)),
        else => error.TypeError,
    };
}

pub fn toIndexForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    const number = try toNumberForAtomics(ctx, output, global, value, caller_function, caller_frame);
    if (std.math.isNan(number)) return 0;
    if (!std.math.isFinite(number)) return error.RangeError;
    const truncated = @trunc(number);
    if (truncated < 0) return error.RangeError;
    return @intFromFloat(truncated);
}

pub fn toNumberForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !f64 {
    _ = caller_function;
    _ = caller_frame;
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    return value_ops.numberValue(number_value) orelse std.math.nan(f64);
}

pub fn toInt32ForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !i32 {
    const bits = try toUint32ForAtomics(ctx, output, global, value, caller_function, caller_frame);
    return @bitCast(@as(u32, @truncate(bits)));
}

pub fn toInt32BitsForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !u64 {
    const int_value = try toInt32ForAtomics(ctx, output, global, value, caller_function, caller_frame);
    return @as(u32, @bitCast(int_value));
}

pub fn toUint32ForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !u64 {
    const number = try toNumberForAtomics(ctx, output, global, value, caller_function, caller_frame);
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const two32 = 4294967296.0;
    var modulo = @mod(@trunc(number), two32);
    if (modulo < 0) modulo += two32;
    return @intFromFloat(modulo);
}

pub fn toIntegerValueForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const number = try toNumberForAtomics(ctx, output, global, value, caller_function, caller_frame);
    if (std.math.isNan(number) or number == 0) return core.JSValue.int32(0);
    if (!std.math.isFinite(number)) return core.JSValue.float64(number);
    return atomicsNumberResult(@trunc(number));
}

pub fn uint32FromIntegerValueForAtomics(rt: *core.JSRuntime, value: core.JSValue) !u64 {
    _ = rt;
    const number = value_ops.numberValue(value) orelse return 0;
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const two32 = 4294967296.0;
    var modulo = @mod(@trunc(number), two32);
    if (modulo < 0) modulo += two32;
    return @intFromFloat(modulo);
}

pub fn toBigIntValueForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = caller_function;
    _ = caller_frame;
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    var big = try value_ops.toBigIntValue(ctx.runtime, primitive);
    defer big.deinit();
    return value_ops.createBigIntValue(ctx.runtime, big);
}

pub fn toBigIntBitsForAtomics(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !u64 {
    const bigint_value = try toBigIntValueForAtomics(ctx, output, global, value, caller_function, caller_frame);
    defer bigint_value.free(ctx.runtime);
    return bigintBitsForAtomics(ctx.runtime, bigint_value);
}

pub fn atomicsNumberResult(value: f64) core.JSValue {
    if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !std.math.isNegativeZero(value)) {
        return core.JSValue.int32(@intFromFloat(value));
    }
    return core.JSValue.float64(value);
}

pub fn bigintBitsForAtomics(rt: *core.JSRuntime, value: core.JSValue) !u64 {
    var big = try value_ops.toBigIntValue(rt, value);
    defer big.deinit();
    var low: u64 = 0;
    if (big.limbs.len >= 1) low |= big.limbs[0];
    if (big.limbs.len >= 2) low |= @as(u64, big.limbs[1]) << 32;
    return if (big.negative) 0 -% low else low;
}

pub fn decodeHexBytes(rt: *core.JSRuntime, source: []const u8, reject_odd: bool) !std.ArrayList(u8) {
    if (reject_odd and source.len % 2 != 0) return error.SyntaxError;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
    var index: usize = 0;
    while (index + 1 < source.len) : (index += 2) {
        const hi = hexNibble(source[index]) orelse return error.SyntaxError;
        const lo = hexNibble(source[index + 1]) orelse return error.SyntaxError;
        try out.append(rt.memory.allocator, (hi << 4) | lo);
    }
    return out;
}

pub fn decodeHexInto(source: []const u8, target: []u8) !Uint8ArrayCodecProgress {
    if (source.len % 2 != 0) return error.SyntaxError;
    var read: usize = 0;
    var written: usize = 0;
    while (read < source.len and written < target.len) {
        const hi = hexNibble(source[read]) orelse return error.SyntaxError;
        const lo = hexNibble(source[read + 1]) orelse return error.SyntaxError;
        target[written] = (hi << 4) | lo;
        read += 2;
        written += 1;
    }
    return .{ .read = read, .written = written };
}

pub fn encodeHexBytes(rt: *core.JSRuntime, bytes: []const u8) !std.ArrayList(u8) {
    const alphabet = "0123456789abcdef";
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
    for (bytes) |byte| {
        try out.append(rt.memory.allocator, alphabet[byte >> 4]);
        try out.append(rt.memory.allocator, alphabet[byte & 0x0f]);
    }
    return out;
}

pub fn hexNibble(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

pub const Base64Chunk = struct {
    bytes: [3]u8 = .{ 0, 0, 0 },
    len: usize = 0,
};

pub fn decodeBase64Bytes(
    rt: *core.JSRuntime,
    source: []const u8,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
    _ = try decodeBase64Internal(rt, source, alphabet, last_chunk_handling, &out, null);
    return out;
}

pub fn decodeBase64Into(
    rt: *core.JSRuntime,
    source: []const u8,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
    target: []u8,
) !Uint8ArrayCodecProgress {
    if (target.len == 0) return .{ .read = 0, .written = 0 };
    return decodeBase64Internal(rt, source, alphabet, last_chunk_handling, null, target);
}

pub fn decodeBase64Internal(
    rt: *core.JSRuntime,
    source: []const u8,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
    out: ?*std.ArrayList(u8),
    target: ?[]u8,
) !Uint8ArrayCodecProgress {
    var chunk: [4]u8 = .{ 0, 0, 0, 0 };
    var chunk_len: usize = 0;
    var read_pos: usize = 0;
    var last_read: usize = 0;
    var written: usize = 0;
    var saw_padded_chunk = false;
    var pending_padded_chunk: ?Base64Chunk = null;
    var pending_padded_read: usize = 0;

    for (source, 0..) |byte, index| {
        if (isAsciiWhitespace(byte)) continue;
        read_pos = index + 1;
        if (saw_padded_chunk) return error.SyntaxError;
        if (byte != '=' and base64Value(byte, alphabet) == null) return error.SyntaxError;
        chunk[chunk_len] = byte;
        chunk_len += 1;
        if (chunk_len == 4) {
            const decoded = try decodeBase64Chunk(chunk, 4, alphabet, last_chunk_handling, false);
            if (chunk[2] == '=' or chunk[3] == '=') {
                pending_padded_chunk = decoded;
                pending_padded_read = read_pos;
                saw_padded_chunk = true;
                chunk_len = 0;
                continue;
            }
            if (target) |bytes| {
                if (decoded.len > bytes.len - written) return .{ .read = last_read, .written = written };
                if (decoded.len != 0) @memcpy(bytes[written..][0..decoded.len], decoded.bytes[0..decoded.len]);
            } else if (out) |list| {
                try list.appendSlice(rt.memory.allocator, decoded.bytes[0..decoded.len]);
            }
            written += decoded.len;
            last_read = read_pos;
            chunk_len = 0;
            if (target) |bytes| {
                if (written == bytes.len) return .{ .read = last_read, .written = written };
            }
        }
    }

    if (pending_padded_chunk) |decoded| {
        if (target) |bytes| {
            if (decoded.len > bytes.len - written) return .{ .read = last_read, .written = written };
            if (decoded.len != 0) @memcpy(bytes[written..][0..decoded.len], decoded.bytes[0..decoded.len]);
        } else if (out) |list| {
            try list.appendSlice(rt.memory.allocator, decoded.bytes[0..decoded.len]);
        }
        written += decoded.len;
        return .{ .read = pending_padded_read, .written = written };
    }
    if (chunk_len == 0) return .{ .read = last_read, .written = written };
    const decoded = try decodeBase64Chunk(chunk, chunk_len, alphabet, last_chunk_handling, true);
    if (decoded.len == 0 and last_chunk_handling == .stop_before_partial) return .{ .read = last_read, .written = written };
    if (target) |bytes| {
        if (decoded.len > bytes.len - written) return .{ .read = last_read, .written = written };
        if (decoded.len != 0) @memcpy(bytes[written..][0..decoded.len], decoded.bytes[0..decoded.len]);
    } else if (out) |list| {
        try list.appendSlice(rt.memory.allocator, decoded.bytes[0..decoded.len]);
    }
    written += decoded.len;
    return .{ .read = read_pos, .written = written };
}

pub fn decodeBase64Chunk(
    chunk: [4]u8,
    chunk_len: usize,
    alphabet: Uint8ArrayBase64Alphabet,
    last_chunk_handling: Uint8ArrayBase64LastChunkHandling,
    is_final: bool,
) !Base64Chunk {
    if (chunk_len == 0) return .{};
    if (chunk_len < 4) {
        var first_padding: ?usize = null;
        var i: usize = 0;
        while (i < chunk_len) : (i += 1) {
            if (chunk[i] == '=') {
                if (first_padding == null) first_padding = i;
            } else if (first_padding != null) {
                return error.SyntaxError;
            }
        }
        if (first_padding) |padding_index| {
            if (padding_index < 2) return error.SyntaxError;
            if (last_chunk_handling == .stop_before_partial and is_final) return .{};
            return error.SyntaxError;
        }
        if (chunk_len == 1) {
            if (last_chunk_handling == .stop_before_partial and is_final) return .{};
            return error.SyntaxError;
        }
        if (last_chunk_handling == .stop_before_partial and is_final) return .{};
        if (last_chunk_handling == .strict) return error.SyntaxError;
        const a = base64Value(chunk[0], alphabet) orelse return error.SyntaxError;
        const b = base64Value(chunk[1], alphabet) orelse return error.SyntaxError;
        var result = Base64Chunk{ .bytes = .{ (a << 2) | (b >> 4), 0, 0 }, .len = 1 };
        if (chunk_len == 3) {
            const c = base64Value(chunk[2], alphabet) orelse return error.SyntaxError;
            result.bytes[1] = ((b & 0x0f) << 4) | (c >> 2);
            result.len = 2;
        }
        return result;
    }

    if (chunk[0] == '=' or chunk[1] == '=') return error.SyntaxError;
    const a = base64Value(chunk[0], alphabet) orelse return error.SyntaxError;
    const b = base64Value(chunk[1], alphabet) orelse return error.SyntaxError;
    if (chunk[2] == '=') {
        if (chunk[3] != '=') return error.SyntaxError;
        if (last_chunk_handling == .strict and (b & 0x0f) != 0) return error.SyntaxError;
        return .{ .bytes = .{ (a << 2) | (b >> 4), 0, 0 }, .len = 1 };
    }
    const c = base64Value(chunk[2], alphabet) orelse return error.SyntaxError;
    if (chunk[3] == '=') {
        if (last_chunk_handling == .strict and (c & 0x03) != 0) return error.SyntaxError;
        return .{ .bytes = .{ (a << 2) | (b >> 4), ((b & 0x0f) << 4) | (c >> 2), 0 }, .len = 2 };
    }
    const d = base64Value(chunk[3], alphabet) orelse return error.SyntaxError;
    return .{ .bytes = .{ (a << 2) | (b >> 4), ((b & 0x0f) << 4) | (c >> 2), ((c & 0x03) << 6) | d }, .len = 3 };
}

pub fn encodeBase64Bytes(rt: *core.JSRuntime, bytes: []const u8, alphabet: Uint8ArrayBase64Alphabet, omit_padding: bool) !std.ArrayList(u8) {
    const table = if (alphabet == .base64) "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" else "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(rt.memory.allocator);
    var index: usize = 0;
    while (index < bytes.len) : (index += 3) {
        const rem = bytes.len - index;
        const b0 = bytes[index];
        const b1 = if (rem > 1) bytes[index + 1] else 0;
        const b2 = if (rem > 2) bytes[index + 2] else 0;
        try out.append(rt.memory.allocator, table[b0 >> 2]);
        try out.append(rt.memory.allocator, table[((b0 & 0x03) << 4) | (b1 >> 4)]);
        if (rem > 1) {
            try out.append(rt.memory.allocator, table[((b1 & 0x0f) << 2) | (b2 >> 6)]);
        } else if (!omit_padding) {
            try out.append(rt.memory.allocator, '=');
        }
        if (rem > 2) {
            try out.append(rt.memory.allocator, table[b2 & 0x3f]);
        } else if (!omit_padding) {
            try out.append(rt.memory.allocator, '=');
        }
    }
    return out;
}

pub fn base64Value(byte: u8, alphabet: Uint8ArrayBase64Alphabet) ?u8 {
    if (byte >= 'A' and byte <= 'Z') return byte - 'A';
    if (byte >= 'a' and byte <= 'z') return byte - 'a' + 26;
    if (byte >= '0' and byte <= '9') return byte - '0' + 52;
    if (alphabet == .base64 and byte == '+') return 62;
    if (alphabet == .base64 and byte == '/') return 63;
    if (alphabet == .base64url and byte == '-') return 62;
    if (alphabet == .base64url and byte == '_') return 63;
    return null;
}

pub fn isAsciiWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

pub fn isIteratorIdentityFunction(rt: *core.JSRuntime, function_object: *core.Object) bool {
    _ = rt;
    return function_object.isIteratorIdentityFunction();
}

pub fn importMetaUrlValue(rt: *core.JSRuntime, record: *core.module.ModuleRecord) !core.JSValue {
    const name = rt.atoms.name(record.module_name) orelse "";
    if (std.mem.startsWith(u8, name, "/") or std.mem.indexOfScalar(u8, name, '/') != null) {
        const path = if (std.mem.startsWith(u8, name, "/"))
            try rt.memory.allocator.dupe(u8, name)
        else
            try std.fs.path.resolve(rt.memory.allocator, &.{name});
        defer rt.memory.allocator.free(path);
        const url = try std.fmt.allocPrint(rt.memory.allocator, "file://{s}", .{path});
        defer rt.memory.allocator.free(url);
        return value_ops.createStringValue(rt, url);
    }
    return value_ops.createStringValue(rt, name);
}

pub fn globalLexicalEnv(ctx: *core.JSContext) !*core.Object {
    if (ctx.lexicals) |env| return env;
    const env = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    ctx.lexicals = env;
    return env;
}

pub fn existingGlobalLexicalEnv(ctx: *core.JSContext) ?*core.Object {
    return ctx.lexicals;
}

pub fn globalLexicalHas(ctx: *core.JSContext, atom_id: core.Atom) bool {
    const env = existingGlobalLexicalEnv(ctx) orelse return false;
    return env.hasOwnProperty(atom_id);
}

pub fn globalLexicalEnvHas(ctx: *core.JSContext, atom_id: core.Atom) bool {
    return globalLexicalHas(ctx, atom_id);
}

pub fn globalLexicalValue(ctx: *core.JSContext, atom_id: core.Atom) ?core.JSValue {
    const env = existingGlobalLexicalEnv(ctx) orelse return null;
    if (env.getOwnDataPropertyValue(atom_id)) |value| return value;
    if (!env.hasOwnProperty(atom_id)) return null;
    return env.getProperty(atom_id);
}

pub fn defineGlobalLexicalValue(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, value: core.JSValue, is_const: bool) !void {
    const env = try globalLexicalEnv(ctx);
    if (!env.hasOwnProperty(atom_id)) {
        const rt = ctx.runtime;
        try env.defineOwnPropertyAssumingNew(rt, atom_id, core.Descriptor.data(value, !is_const, false, false));
        global.shape_ref.version +%= 1;
    }
}

pub fn setGlobalLexicalValue(ctx: *core.JSContext, atom_id: core.Atom, value: core.JSValue) !bool {
    const env = existingGlobalLexicalEnv(ctx) orelse return false;
    if (!env.hasOwnProperty(atom_id)) return false;
    const rt = ctx.runtime;
    if (initializeGlobalLexicalValue(rt, env, atom_id, value)) return true;
    if (try env.setOwnWritableDataProperty(rt, atom_id, value)) return true;
    env.setProperty(rt, atom_id, value) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        else => return err,
    };
    return true;
}

pub fn setGlobalLexicalValueForFastPathOwned(ctx: *core.JSContext, atom_id: core.Atom, value: core.JSValue) !bool {
    const env = existingGlobalLexicalEnv(ctx) orelse return false;
    const index = env.findProperty(atom_id) orelse return false;
    return env.setOwnDataPropertyAtForLexicalSyncOwned(ctx.runtime, index, atom_id, value);
}

pub fn initializeGlobalLexicalValue(rt: *core.JSRuntime, env: *core.Object, atom_id: core.Atom, value: core.JSValue) bool {
    for (env.properties) |*entry| {
        if (entry.atom_id == core.atom.null_atom) continue;
        if (!atomIdOrNameEql(rt, entry.atom_id, atom_id)) continue;
        switch (entry.slot) {
            .data => |*stored| {
                if (!stored.isUninitialized()) return false;
                const next = value.dup();
                const old_value = stored.*;
                stored.* = next;
                old_value.free(rt);
                return true;
            },
            else => return false,
        }
    }
    return false;
}

pub fn directEval(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    eval_in_class_field_initializer: bool,
    eval_in_parameter_initializer: bool,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.undefinedValue();
    if (!args[0].isString()) return args[0].dup();
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try appendSourceStringUtf8(ctx.runtime, &source, args[0]);
    if (try simpleEvalRegExpLiteral(ctx, global, source.items)) |value| return value;
    if (try evalSimpleCallerExpression(ctx, source.items, caller_function, caller_frame)) |value| return value;
    const caller_strict = if (caller_function) |outer_function| outer_function.flags.is_strict else false;
    if (caller_function) |outer_function| {
        if (!outer_function.flags.has_simple_parameter_list) {
            if (simpleVarDeclarationName(source.items)) |name| {
                const caller_has_arguments_binding = if (caller_frame) |outer_frame|
                    directEvalShouldExposeImplicitArguments(outer_frame)
                else
                    false;
                if ((std.mem.eql(u8, name, "arguments") and caller_has_arguments_binding) or
                    callerFunctionHasArg(ctx.runtime, outer_function, name))
                {
                    return error.SyntaxError;
                }
            }
        }
        if (!caller_strict) if (simpleVarDeclarationName(source.items)) |name| {
            if (!eval_in_parameter_initializer and callerFunctionHasLexicalLocal(ctx.runtime, outer_function, name)) return error.SyntaxError;
        };
    }
    const eval_global_var_bindings = if (caller_frame) |outer_frame|
        outer_frame.current_function.isUndefined()
    else
        true;
    const eval_allows_new_target = directEvalCallerAllowsNewTarget(caller_frame, eval_in_class_field_initializer);
    const eval_allows_super_property = directEvalCallerAllowsSuperProperty(caller_frame, eval_in_class_field_initializer);
    const eval_class_static_field_this_atom = classStaticThisAtom(ctx.runtime, caller_function, caller_frame);
    const eval_private_bound_names = try directEvalPrivateBoundNames(ctx.runtime, caller_function, caller_frame);
    defer if (eval_private_bound_names.len != 0) ctx.runtime.memory.free(core.Atom, eval_private_bound_names);
    var compiled = try frontend.parser.parse(ctx.runtime, source.items, .{
        .mode = .eval_direct,
        .filename = "<eval>",
        .strict = caller_strict,
        .eval_global_var_bindings = eval_global_var_bindings,
        .eval_in_class_field_initializer = eval_in_class_field_initializer,
        .eval_allows_new_target = eval_allows_new_target,
        .eval_allows_super_property = eval_allows_super_property,
        .eval_class_static_field_this_atom = eval_class_static_field_this_atom,
        .eval_private_bound_names = eval_private_bound_names,
    });
    defer compiled.deinit();
    if (compiled.syntax_error != null) return error.SyntaxError;
    const eval_strict = compiled.function.flags.is_strict;
    if (eval_global_var_bindings and !eval_strict) {
        try validateGlobalEvalFunctionDeclarations(ctx, global, source.items, false);
    }
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    var empty_locals: [0]core.JSValue = .{};
    const inherited_local_names = if (caller_frame) |outer_frame| outer_frame.eval_local_names else &.{};
    const inherited_locals = if (caller_frame) |outer_frame| outer_frame.eval_local_slots else empty_locals[0..];
    const inherited_ref_names = if (caller_frame) |outer_frame| outer_frame.eval_var_ref_names else &.{};
    const inherited_refs = if (caller_frame) |outer_frame| outer_frame.eval_var_refs else &.{};
    const outer_refs = if (caller_frame) |outer_frame| outer_frame.var_refs else &.{};
    const outer_names = if (caller_function) |outer_function| outer_function.var_ref_names else &.{};
    const base_outer_local_names = if (caller_function) |outer_function| outer_function.var_names else &.{};
    const base_outer_locals = if (caller_frame) |outer_frame| outer_frame.locals else empty_locals[0..];
    var direct_eval_local_names: []core.Atom = &.{};
    var direct_eval_local_slots: []core.JSValue = &.{};
    defer freeAtomSlice(ctx.runtime, direct_eval_local_names);
    defer freeValueSlice(ctx.runtime, direct_eval_local_slots);
    var direct_eval_local_slots_root = ValueSliceRoot{};
    direct_eval_local_slots_root.init(ctx.runtime, &direct_eval_local_slots);
    defer direct_eval_local_slots_root.deinit();
    if (caller_function) |outer_function| {
        if (caller_frame) |outer_frame| {
            const bindings = try createDirectEvalVisibleLocalBindings(ctx, global, outer_function, outer_frame, eval_in_parameter_initializer, eval_global_var_bindings);
            direct_eval_local_names = bindings.names;
            direct_eval_local_slots = bindings.slots;
        }
    }
    const outer_local_names = if (direct_eval_local_names.len != 0) direct_eval_local_names else if (eval_global_var_bindings) &.{} else base_outer_local_names;
    const outer_locals = if (direct_eval_local_names.len != 0) direct_eval_local_slots else if (eval_global_var_bindings) empty_locals[0..] else base_outer_locals;
    var eval_function_names: []core.Atom = &.{};
    if (!eval_strict) {
        if (try evalFunctionDeclarationNames(ctx.runtime, source.items)) |names| {
            eval_function_names = names;
        }
    }
    defer freeAtomSlice(ctx.runtime, eval_function_names);
    var eval_var_names: []core.Atom = &.{};
    if (!eval_strict) {
        eval_var_names = try directEvalVarDeclarationNames(ctx.runtime, global, &compiled.function, source.items, caller_function, eval_function_names, eval_global_var_bindings);
    }
    defer if (!eval_strict) freeAtomSlice(ctx.runtime, eval_var_names);
    var eval_var_refs = try createDirectEvalVarRefCells(ctx, eval_var_names, caller_function, caller_frame, eval_in_parameter_initializer);
    defer freeValueSlice(ctx.runtime, eval_var_refs);
    var eval_var_refs_root = ValueSliceRoot{};
    eval_var_refs_root.init(ctx.runtime, &eval_var_refs);
    defer eval_var_refs_root.deinit();
    var combined_eval_local_names: []core.Atom = &.{};
    var combined_eval_local_slots: []core.JSValue = &.{};
    defer freeAtomSlice(ctx.runtime, combined_eval_local_names);
    defer freeValueSlice(ctx.runtime, combined_eval_local_slots);
    var rooted_combined_eval_local_slots: []core.JSValue = &.{};
    var combined_eval_local_slots_root = ValueSliceRoot{};
    combined_eval_local_slots_root.init(ctx.runtime, &rooted_combined_eval_local_slots);
    defer combined_eval_local_slots_root.deinit();
    if (eval_var_names.len != 0) {
        const outer_count = @min(outer_local_names.len, outer_locals.len);
        const eval_count = @min(eval_var_names.len, eval_var_refs.len);
        if (outer_count + eval_count != 0) {
            combined_eval_local_names = try ctx.runtime.memory.alloc(core.Atom, outer_count + eval_count);
            errdefer {
                ctx.runtime.memory.free(core.Atom, combined_eval_local_names);
                combined_eval_local_names = &.{};
            }
            combined_eval_local_slots = try ctx.runtime.memory.alloc(core.JSValue, outer_count + eval_count);
            errdefer {
                ctx.runtime.memory.free(core.JSValue, combined_eval_local_slots);
                combined_eval_local_slots = &.{};
            }
            var combined_idx: usize = 0;
            errdefer {
                for (combined_eval_local_names[0..combined_idx]) |atom_id| ctx.runtime.atoms.free(atom_id);
                for (combined_eval_local_slots[0..combined_idx]) |*value| {
                    value.free(ctx.runtime);
                    value.* = core.JSValue.undefinedValue();
                }
                rooted_combined_eval_local_slots = &.{};
            }
            for (outer_local_names[0..outer_count], 0..) |atom_id, idx| {
                combined_eval_local_names[combined_idx] = ctx.runtime.atoms.dup(atom_id);
                combined_eval_local_slots[combined_idx] = outer_locals[idx].dup();
                combined_idx += 1;
                rooted_combined_eval_local_slots = combined_eval_local_slots[0..combined_idx];
            }
            for (eval_var_names[0..eval_count], 0..) |atom_id, idx| {
                combined_eval_local_names[combined_idx] = ctx.runtime.atoms.dup(atom_id);
                combined_eval_local_slots[combined_idx] = eval_var_refs[idx].dup();
                combined_idx += 1;
                rooted_combined_eval_local_slots = combined_eval_local_slots[0..combined_idx];
            }
        }
    }
    const run_eval_local_names = if (combined_eval_local_names.len != 0) combined_eval_local_names else outer_local_names;
    const run_eval_local_slots = if (combined_eval_local_names.len != 0) combined_eval_local_slots else outer_locals;
    const eval_this = directEvalThisValue(ctx.runtime, caller_function, caller_frame);
    const eval_new_target = if (eval_allows_new_target) blk: {
        if (caller_frame) |outer_frame| break :blk outer_frame.new_target;
        break :blk core.JSValue.undefinedValue();
    } else core.JSValue.undefinedValue();
    const eval_current_function = blk: {
        if (caller_frame) |outer_frame| break :blk outer_frame.current_function;
        break :blk core.JSValue.undefinedValue();
    };
    const eval_with_object = directEvalWithObject(ctx.runtime, caller_function, caller_frame);
    defer eval_with_object.free(ctx.runtime);
    const result = try runWithArgsState(ctx, &nested_stack, &compiled.function, eval_this, &.{}, eval_var_refs, output, global, false, eval_strict, false, run_eval_local_names, run_eval_local_slots, outer_names, outer_refs, inherited_local_names, inherited_locals, inherited_ref_names, inherited_refs, null, null, null, eval_current_function, eval_new_target, core.JSValue.undefinedValue(), eval_global_var_bindings, true, eval_with_object, false, false);
    errdefer result.free(ctx.runtime);
    try publishDirectEvalVarRefs(ctx, global, caller_frame, eval_var_names, eval_var_refs, eval_in_parameter_initializer, eval_global_var_bindings);
    return result;
}

pub fn validateGlobalEvalFunctionDeclarations(
    ctx: *core.JSContext,
    global: *core.Object,
    source: []const u8,
    ignore_global_lexical: bool,
) !void {
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, source[search_start..], "function")) |rel| {
        const keyword_index = search_start + rel;
        if (!looksLikeStatementFunctionKeyword(source, keyword_index)) {
            search_start = keyword_index + "function".len;
            continue;
        }
        var cursor = skipAsciiWhitespace(source, keyword_index + "function".len);
        if (cursor < source.len and source[cursor] == '*') {
            cursor = skipAsciiWhitespace(source, cursor + 1);
        }
        if (cursor >= source.len or !isIdentifierStartByte(source[cursor])) {
            search_start = keyword_index + "function".len;
            continue;
        }
        const name_start = cursor;
        cursor += 1;
        while (cursor < source.len and isIdentifierPartByte(source[cursor])) : (cursor += 1) {}
        const atom_id = try ctx.runtime.internAtom(source[name_start..cursor]);
        defer ctx.runtime.atoms.free(atom_id);
        if (!canDeclareGlobalFunction(ctx, global, atom_id, ignore_global_lexical)) return error.TypeError;
        search_start = cursor;
    }
}

pub fn looksLikeStatementFunctionKeyword(source: []const u8, keyword_index: usize) bool {
    if (keyword_index > 0 and isIdentifierPartByte(source[keyword_index - 1])) return false;
    const after = keyword_index + "function".len;
    if (after < source.len and isIdentifierPartByte(source[after])) return false;
    if (keyword_index == 0) return true;
    var cursor = keyword_index;
    while (cursor > 0) {
        cursor -= 1;
        const ch = source[cursor];
        if (std.ascii.isWhitespace(ch)) continue;
        return ch == ';' or ch == '{' or ch == '}';
    }
    return true;
}

pub fn canDeclareGlobalFunction(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, ignore_global_lexical: bool) bool {
    if (!ignore_global_lexical and globalLexicalHas(ctx, atom_id)) return false;
    const rt = ctx.runtime;
    const desc = global.getOwnProperty(atom_id) orelse return global.isExtensible();
    defer desc.destroy(rt);
    if (desc.configurable == true) return true;
    if (desc.kind != .data) return false;
    return desc.writable == true and desc.enumerable == true;
}

pub fn isIdentifierStartByte(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$';
}

pub fn isIdentifierPartByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

pub fn directEvalThisValue(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) core.JSValue {
    const outer_frame = caller_frame orelse return core.JSValue.undefinedValue();
    if (classStaticThisAtom(rt, caller_function, caller_frame)) |atom_id| {
        if (classStaticThisValue(caller_function, outer_frame, atom_id)) |value| return value;
    }
    return outer_frame.this_value;
}

pub fn classStaticThisAtom(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) ?core.Atom {
    const function = caller_function orelse return null;
    const frame = caller_frame orelse return null;
    const count = @min(function.var_names.len, frame.locals.len);
    var idx = count;
    while (idx > 0) {
        idx -= 1;
        const atom_id = function.var_names[idx];
        const name = rt.atoms.name(atom_id) orelse continue;
        if (!std.mem.startsWith(u8, name, "__class_static_this_")) continue;
        if (frame.locals[idx].isUninitialized()) continue;
        return atom_id;
    }
    return null;
}

pub fn classStaticThisValue(
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
    atom_id: core.Atom,
) ?core.JSValue {
    const function = caller_function orelse return null;
    const count = @min(function.var_names.len, caller_frame.locals.len);
    for (function.var_names[0..count], 0..) |name, idx| {
        if (name != atom_id) continue;
        const value = caller_frame.locals[idx];
        if (value.isUninitialized()) continue;
        return value;
    }
    return null;
}

test "direct eval private bound names release preserves memory account" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function_name = try rt.internAtom("privateBoundCaller");
    defer rt.atoms.free(function_name);
    const private_name = try rt.atoms.newSymbol("privateBoundName", .private);
    defer rt.atoms.free(private_name);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, function_name);
    defer function.deinit(rt);
    function.private_bound_names = try rt.memory.alloc(core.Atom, 1);
    function.private_bound_names[0] = rt.atoms.dup(private_name);

    const before_bytes = rt.memory.allocated_bytes;
    const before_allocations = rt.memory.allocation_count;
    const names = try directEvalPrivateBoundNames(rt, &function, null);
    if (names.len != 0) rt.memory.free(core.Atom, names);
    try std.testing.expectEqual(before_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(before_allocations, rt.memory.allocation_count);
}

test "eval function declaration names release preserves memory account" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const warm = try rt.internAtom("evalMemoryAccountName");
    rt.atoms.free(warm);

    const before_bytes = rt.memory.allocated_bytes;
    const before_allocations = rt.memory.allocation_count;
    const names = (try evalFunctionDeclarationNames(rt, "function evalMemoryAccountName() {}")).?;
    freeAtomSlice(rt, names);
    try std.testing.expectEqual(before_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(before_allocations, rt.memory.allocation_count);
}

pub fn directEvalPrivateBoundNames(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) ![]core.Atom {
    var atoms = std.ArrayList(core.Atom).empty;
    errdefer atoms.deinit(rt.memory.allocator);
    if (caller_function) |function| {
        for (function.private_bound_names) |atom_id| {
            try appendPrivateBoundName(rt, &atoms, atom_id);
        }
        for (function.atom_operands) |atom_id| {
            try appendPrivateBoundName(rt, &atoms, atom_id);
        }
    }
    if (caller_frame) |frame| {
        try appendPrivateBoundNamesFromValue(rt, &atoms, frame.this_value);
        if (objectFromValue(frame.current_function)) |function_object| {
            if (function_object.functionHomeObjectSlot().*) |home_object| {
                try appendPrivateBoundNamesFromObject(rt, &atoms, home_object);
            }
        }
    }
    return try atomListToMemorySlice(rt, &atoms);
}

pub fn appendPrivateBoundNamesFromValue(
    rt: *core.JSRuntime,
    atoms: *std.ArrayList(core.Atom),
    value: core.JSValue,
) !void {
    const object = objectFromValue(value) orelse return;
    try appendPrivateBoundNamesFromObject(rt, atoms, object);
}

pub fn appendPrivateBoundName(
    rt: *core.JSRuntime,
    atoms: *std.ArrayList(core.Atom),
    atom_id: core.Atom,
) !void {
    if (rt.atoms.kind(atom_id) != .private) return;
    for (atoms.items) |existing| {
        if (existing == atom_id or privateAtomNamesMatch(rt, existing, atom_id)) return;
    }
    try atoms.append(rt.memory.allocator, atom_id);
}

pub fn evalFunctionDeclarationNames(rt: *core.JSRuntime, source: []const u8) !?[]core.Atom {
    var atoms = std.ArrayList(core.Atom).empty;
    errdefer {
        for (atoms.items) |atom_id| rt.atoms.free(atom_id);
        atoms.deinit(rt.memory.allocator);
    }
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, source[search_start..], "function")) |rel| {
        const keyword_index = search_start + rel;
        if (!looksLikeStatementFunctionKeyword(source, keyword_index)) {
            search_start = keyword_index + "function".len;
            continue;
        }
        if (braceDepthBefore(source, keyword_index) != 0) {
            search_start = keyword_index + "function".len;
            continue;
        }
        if (try evalFunctionDeclarationNameAt(rt, source, keyword_index)) |atom_id| {
            var duplicate = false;
            for (atoms.items) |existing| {
                if (atomIdOrNameEql(rt, existing, atom_id)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) {
                rt.atoms.free(atom_id);
            } else {
                errdefer rt.atoms.free(atom_id);
                try atoms.append(rt.memory.allocator, atom_id);
            }
        }
        search_start = keyword_index + "function".len;
    }
    if (atoms.items.len == 0) return null;
    return try atomListToMemorySlice(rt, &atoms);
}

pub fn braceDepthBefore(source: []const u8, end: usize) usize {
    var depth: usize = 0;
    var index: usize = 0;
    while (index < end and index < source.len) : (index += 1) {
        switch (source[index]) {
            '{' => depth += 1,
            '}' => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
    }
    return depth;
}

pub fn evalFunctionDeclarationNameAt(rt: *core.JSRuntime, source: []const u8, keyword_index: usize) !?core.Atom {
    var index = keyword_index + "function".len;
    index = skipAsciiWhitespace(source, index);
    if (index < source.len and source[index] == '*') {
        index += 1;
        index = skipAsciiWhitespace(source, index);
    }
    var name_bytes = std.ArrayList(u8).empty;
    defer name_bytes.deinit(rt.memory.allocator);
    while (index < source.len) {
        const b = source[index];
        if (b == '(' or std.ascii.isWhitespace(b)) break;
        if (b == '\\' and index + 1 < source.len and source[index + 1] == 'u') {
            try appendIdentifierEscape(rt, &name_bytes, source, &index);
            continue;
        }
        if (!isIdentifierPartByte(b)) return null;
        try name_bytes.append(rt.memory.allocator, b);
        index += 1;
    }
    if (name_bytes.items.len == 0) return null;
    const after_name = skipAsciiWhitespace(source, index);
    if (after_name >= source.len or source[after_name] != '(') return null;
    return try rt.internAtom(name_bytes.items);
}

pub fn simpleEvalFunctionDeclarationNames(rt: *core.JSRuntime, source: []const u8) !?[]core.Atom {
    var index = skipAsciiWhitespace(source, 0);
    if (!startsWithKeyword(source[index..], "function")) return null;
    index += "function".len;
    index = skipAsciiWhitespace(source, index);
    if (index < source.len and source[index] == '*') {
        index += 1;
        index = skipAsciiWhitespace(source, index);
    }
    var name_bytes = std.ArrayList(u8).empty;
    defer name_bytes.deinit(rt.memory.allocator);
    while (index < source.len) {
        const b = source[index];
        if (b == '(' or std.ascii.isWhitespace(b)) break;
        if (b == '\\' and index + 1 < source.len and source[index + 1] == 'u') {
            try appendIdentifierEscape(rt, &name_bytes, source, &index);
            continue;
        }
        try name_bytes.append(rt.memory.allocator, b);
        index += 1;
    }
    if (name_bytes.items.len == 0) return null;
    const after_name = skipAsciiWhitespace(source, index);
    if (after_name >= source.len or source[after_name] != '(') return null;
    const names = try rt.memory.alloc(core.Atom, 1);
    errdefer rt.memory.free(core.Atom, names);
    names[0] = try rt.internAtom(name_bytes.items);
    return names;
}

pub fn skipAsciiWhitespace(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
    return index;
}

pub fn startsWithKeyword(source: []const u8, keyword: []const u8) bool {
    if (!std.mem.startsWith(u8, source, keyword)) return false;
    if (source.len == keyword.len) return true;
    const next = source[keyword.len];
    return !std.ascii.isAlphanumeric(next) and next != '_' and next != '$';
}

pub fn appendIdentifierEscape(rt: *core.JSRuntime, out: *std.ArrayList(u8), source: []const u8, index: *usize) !void {
    if (index.* + 6 > source.len) return error.SyntaxError;
    const hex = source[index.* + 2 .. index.* + 6];
    const code = std.fmt.parseInt(u21, hex, 16) catch return error.SyntaxError;
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(code, &buf);
    index.* += 6;
    try out.appendSlice(rt.memory.allocator, buf[0..len]);
}

pub fn createEvalVarRefCells(ctx: *core.JSContext, len: usize) ![]core.JSValue {
    if (len == 0) return &.{};
    const refs = try ctx.runtime.memory.alloc(core.JSValue, len);
    var rooted_refs: []core.JSValue = refs[0..0];
    var refs_root = ValueSliceRoot{};
    refs_root.init(ctx.runtime, &rooted_refs);
    defer refs_root.deinit();
    var initialized: usize = 0;
    errdefer {
        for (refs[0..initialized]) |*value| {
            value.free(ctx.runtime);
            value.* = core.JSValue.undefinedValue();
        }
        rooted_refs = &.{};
        ctx.runtime.memory.free(core.JSValue, refs);
    }
    while (initialized < len) : (initialized += 1) {
        const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
        try object.initVarRefPayload(ctx.runtime, core.JSValue.undefinedValue());
        refs[initialized] = object.value();
        rooted_refs = refs[0 .. initialized + 1];
    }
    return refs;
}

test "createEvalVarRefCells roots initialized refs while allocating next cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const Probe = struct {
        rt: *core.JSRuntime,
        saw_var_ref: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const saved_trigger_fn = self.rt.memory.trigger_gc_fn;
            const saved_trigger_ctx = self.rt.memory.trigger_gc_ctx;
            self.rt.memory.trigger_gc_fn = null;
            self.rt.memory.trigger_gc_ctx = null;
            defer {
                self.rt.memory.trigger_gc_fn = saved_trigger_fn;
                self.rt.memory.trigger_gc_ctx = saved_trigger_ctx;
            }
            var visitor = core.runtime.RootVisitor{
                .context = self,
                .visit_value = @This().visitValue,
                .visit_object = @This().visitObject,
            };
            self.rt.traceActiveRoots(&visitor) catch {
                self.trace_failed = true;
            };
        }

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const object = objectFromValue(slot.*) orelse return;
            if (object.class_payload_kind == .var_ref) self.saw_var_ref = true;
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var probe = Probe{ .rt = rt };
    rt.memory.trigger_gc_fn = Probe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    errdefer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    const refs = try createEvalVarRefCells(ctx, 2);
    rt.memory.trigger_gc_fn = saved_trigger_fn;
    rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    defer freeValueSlice(rt, refs);

    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.saw_var_ref);
}

pub fn createDirectEvalVarRefCells(
    ctx: *core.JSContext,
    names: []const core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    eval_in_parameter_initializer: bool,
) ![]core.JSValue {
    if (names.len == 0) return &.{};
    const refs = try ctx.runtime.memory.alloc(core.JSValue, names.len);
    var rooted_refs: []core.JSValue = refs[0..0];
    var refs_root = ValueSliceRoot{};
    refs_root.init(ctx.runtime, &rooted_refs);
    defer refs_root.deinit();
    var initialized: usize = 0;
    errdefer {
        for (refs[0..initialized]) |*value| {
            value.free(ctx.runtime);
            value.* = core.JSValue.undefinedValue();
        }
        rooted_refs = &.{};
        ctx.runtime.memory.free(core.JSValue, refs);
    }
    while (initialized < names.len) : (initialized += 1) {
        if (caller_function) |function| {
            if (caller_frame) |frame| {
                if (callerArgIndex(ctx.runtime, function, names[initialized])) |arg_idx| {
                    if (arg_idx < frame.args.len) {
                        refs[initialized] = try ensureVarRefCell(ctx, &frame.args[arg_idx]);
                        rooted_refs = refs[0 .. initialized + 1];
                        continue;
                    }
                }
                if (!eval_in_parameter_initializer) {
                    if (callerLocalIndex(ctx.runtime, function, names[initialized])) |local_idx| {
                        if (local_idx < frame.locals.len) {
                            refs[initialized] = try ensureVarRefCell(ctx, &frame.locals[local_idx]);
                            rooted_refs = refs[0 .. initialized + 1];
                            continue;
                        }
                    }
                }
            }
        }
        const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
        try object.initVarRefPayload(ctx.runtime, core.JSValue.undefinedValue());
        object.varRefIsDeletableSlot().* = true;
        refs[initialized] = object.value();
        rooted_refs = refs[0 .. initialized + 1];
    }
    return refs;
}

pub const DirectEvalVisibleLocalBindings = struct {
    names: []core.Atom,
    slots: []core.JSValue,
};

pub fn createDirectEvalVisibleLocalBindings(
    ctx: *core.JSContext,
    global: *core.Object,
    caller_function: *const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
    eval_in_parameter_initializer: bool,
    eval_global_var_bindings: bool,
) !DirectEvalVisibleLocalBindings {
    const arg_count = @min(caller_function.arg_names.len, caller_frame.args.len);
    const local_count = if (eval_in_parameter_initializer) 0 else @min(caller_function.var_names.len, caller_frame.locals.len);
    const include_implicit_arguments =
        directEvalShouldExposeImplicitArguments(caller_frame) and
        !functionHasArgOrLocal(caller_function, core.atom.ids.arguments, arg_count, local_count);
    const count = arg_count + local_count + @as(usize, if (include_implicit_arguments) 1 else 0);
    if (count == 0) return .{ .names = &.{}, .slots = &.{} };
    const names = try ctx.runtime.memory.alloc(core.Atom, count);
    errdefer ctx.runtime.memory.free(core.Atom, names);
    const slots = try ctx.runtime.memory.alloc(core.JSValue, count);
    errdefer ctx.runtime.memory.free(core.JSValue, slots);
    var rooted_slots: []core.JSValue = slots[0..0];
    var slots_root = ValueSliceRoot{};
    slots_root.init(ctx.runtime, &rooted_slots);
    defer slots_root.deinit();
    var initialized: usize = 0;
    var initialized_names: usize = 0;
    errdefer {
        for (names[0..initialized_names]) |atom_id| ctx.runtime.atoms.free(atom_id);
        for (slots[0..initialized]) |*value| {
            value.free(ctx.runtime);
            value.* = core.JSValue.undefinedValue();
        }
        rooted_slots = &.{};
    }
    var local_index = local_count;
    while (local_index > 0) {
        local_index -= 1;
        const atom_id = caller_function.var_names[local_index];
        if (atom_id == core.atom.null_atom) continue;
        if (directEvalVisibleBindingExists(ctx.runtime, names[0..initialized], atom_id)) continue;
        if (eval_global_var_bindings and
            globalLexicalHas(ctx, atom_id) and
            directEvalVisibleLocalNameCount(ctx.runtime, caller_function.var_names[0..local_count], atom_id) == 1)
        {
            continue;
        }
        names[initialized] = ctx.runtime.atoms.dup(atom_id);
        initialized_names += 1;
        slots[initialized] = try ensureVarRefCell(ctx, &caller_frame.locals[local_index]);
        initialized += 1;
        rooted_slots = slots[0..initialized];
    }
    var arg_index = arg_count;
    while (arg_index > 0) {
        arg_index -= 1;
        const atom_id = caller_function.arg_names[arg_index];
        if (atom_id == core.atom.null_atom) continue;
        if (directEvalVisibleBindingExists(ctx.runtime, names[0..initialized], atom_id)) continue;
        names[initialized] = ctx.runtime.atoms.dup(atom_id);
        initialized_names += 1;
        slots[initialized] = try ensureVarRefCell(ctx, &caller_frame.args[arg_index]);
        initialized += 1;
        rooted_slots = slots[0..initialized];
    }
    if (include_implicit_arguments) {
        names[initialized] = ctx.runtime.atoms.dup(core.atom.ids.arguments);
        initialized_names += 1;
        slots[initialized] = try frameArgumentsObject(ctx, global, caller_frame);
        initialized += 1;
        rooted_slots = slots[0..initialized];
    }
    if (initialized == 0) {
        rooted_slots = &.{};
        ctx.runtime.memory.free(core.Atom, names);
        ctx.runtime.memory.free(core.JSValue, slots);
        return .{ .names = &.{}, .slots = &.{} };
    }
    if (initialized != count) {
        const compact_names = try ctx.runtime.memory.alloc(core.Atom, initialized);
        errdefer ctx.runtime.memory.free(core.Atom, compact_names);
        const compact_slots = try ctx.runtime.memory.alloc(core.JSValue, initialized);
        errdefer ctx.runtime.memory.free(core.JSValue, compact_slots);
        @memcpy(compact_names, names[0..initialized]);
        @memcpy(compact_slots, slots[0..initialized]);
        rooted_slots = compact_slots[0..initialized];
        ctx.runtime.memory.free(core.Atom, names);
        ctx.runtime.memory.free(core.JSValue, slots);
        return .{ .names = compact_names, .slots = compact_slots };
    }
    return .{ .names = names, .slots = slots };
}

pub fn directEvalVisibleBindingExists(rt: *core.JSRuntime, names: []const core.Atom, atom_id: core.Atom) bool {
    for (names) |existing| {
        if (atomIdOrNameEql(rt, existing, atom_id)) return true;
    }
    return false;
}

pub fn directEvalVisibleLocalNameCount(rt: *core.JSRuntime, names: []const core.Atom, atom_id: core.Atom) usize {
    var count: usize = 0;
    for (names) |existing| {
        if (atomIdOrNameEql(rt, existing, atom_id)) count += 1;
    }
    return count;
}

pub fn directEvalShouldExposeImplicitArguments(caller_frame: *frame_mod.Frame) bool {
    if (caller_frame.current_function.isUndefined()) return false;
    if (functionBytecodeFromValue(caller_frame.current_function)) |fb| return !fb.is_arrow_function;
    if (objectFromValue(caller_frame.current_function)) |function_object| {
        const stored = function_object.functionBytecodeSlot().* orelse return false;
        const fb = functionBytecodeFromValue(stored) orelse return false;
        return !fb.is_arrow_function;
    }
    return false;
}

pub fn frameCurrentFunctionIsArrow(caller_frame: *frame_mod.Frame) bool {
    if (functionBytecodeFromValue(caller_frame.current_function)) |fb| return fb.is_arrow_function;
    if (objectFromValue(caller_frame.current_function)) |function_object| {
        const stored = function_object.functionBytecodeSlot().* orelse return false;
        const fb = functionBytecodeFromValue(stored) orelse return false;
        return fb.is_arrow_function;
    }
    return false;
}

pub fn directEvalCallerAllowsNewTarget(caller_frame: ?*frame_mod.Frame, eval_in_class_field_initializer: bool) bool {
    if (eval_in_class_field_initializer) return true;
    const outer_frame = caller_frame orelse return false;
    if (outer_frame.current_function.isUndefined()) return false;
    if (functionBytecodeFromValue(outer_frame.current_function)) |fb| return fb.new_target_allowed;
    if (objectFromValue(outer_frame.current_function)) |function_object| {
        const stored = function_object.functionBytecodeSlot().* orelse return false;
        const fb = functionBytecodeFromValue(stored) orelse return false;
        return fb.new_target_allowed;
    }
    return false;
}

pub fn functionHasArgOrLocal(
    function: *const bytecode.Bytecode,
    atom_id: core.Atom,
    arg_count: usize,
    local_count: usize,
) bool {
    for (function.arg_names[0..arg_count]) |name| {
        if (name == atom_id) return true;
    }
    for (function.var_names[0..local_count]) |name| {
        if (name == atom_id) return true;
    }
    return false;
}

pub fn callerArgIndex(rt: *core.JSRuntime, function: *const bytecode.Bytecode, atom_id: core.Atom) ?usize {
    for (function.arg_names, 0..) |name, idx| {
        if (atomIdOrNameEql(rt, name, atom_id)) return idx;
    }
    return null;
}

pub fn callerLocalIndex(rt: *core.JSRuntime, function: *const bytecode.Bytecode, atom_id: core.Atom) ?usize {
    const count = @min(function.var_names.len, function.var_is_lexical.len);
    for (function.var_names[0..count], 0..) |name, idx| {
        if (!atomIdOrNameEql(rt, name, atom_id)) continue;
        if (function.var_is_lexical[idx]) continue;
        return idx;
    }
    return null;
}

pub fn directEvalVarDeclarationNames(
    rt: *core.JSRuntime,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    source: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    function_decl_names: []const core.Atom,
    eval_global_var_bindings: bool,
) ![]core.Atom {
    const simple_var_name = if (simpleVarDeclarationName(source)) |name| try rt.internAtom(name) else core.atom.null_atom;
    defer if (simple_var_name != core.atom.null_atom) rt.atoms.free(simple_var_name);
    const count = blk: {
        var n: usize = 0;
        const local_count = @min(function.var_names.len, function.var_is_lexical.len);
        for (function.var_names[0..local_count], 0..) |atom_id, idx| {
            if (atom_id == core.atom.null_atom) continue;
            if (atom_id == eval_ret_atom) continue;
            if (directEvalVarNameIsNonLeadingFunctionCallerArg(rt, source, caller_function, atom_id)) continue;
            if (directEvalSourceHasLexicalDeclarationName(rt, source, atom_id)) continue;
            const is_lexical = function.var_is_lexical[idx];
            if (!is_lexical and eval_global_var_bindings and !directEvalVarDeclarationShouldCreateRef(rt, global, atom_id)) continue;
            if (!is_lexical) n += 1;
        }
        for (function_decl_names) |atom_id| {
            if (atom_id == eval_ret_atom) continue;
            if (directEvalSourceHasLexicalDeclarationName(rt, source, atom_id)) continue;
            if (!functionHasNonLexicalLocal(rt, function, atom_id)) n += 1;
        }
        if (simple_var_name != core.atom.null_atom and
            simple_var_name != eval_ret_atom and
            (!eval_global_var_bindings or directEvalGlobalDataVarNeedsTemporaryRef(rt, global, simple_var_name)) and
            !functionHasNonLexicalLocal(rt, function, simple_var_name) and
            !atomSliceContains(rt, function_decl_names, simple_var_name) and
            !directEvalSourceHasLexicalDeclarationName(rt, source, simple_var_name))
        {
            n += 1;
        }
        break :blk n;
    };
    if (count == 0) return &.{};
    const names = try rt.memory.alloc(core.Atom, count);
    errdefer rt.memory.free(core.Atom, names);
    var out_idx: usize = 0;
    const local_count = @min(function.var_names.len, function.var_is_lexical.len);
    for (function.var_names[0..local_count], 0..) |atom_id, idx| {
        if (atom_id == core.atom.null_atom) continue;
        if (atom_id == eval_ret_atom) continue;
        if (directEvalVarNameIsNonLeadingFunctionCallerArg(rt, source, caller_function, atom_id)) continue;
        if (directEvalSourceHasLexicalDeclarationName(rt, source, atom_id)) continue;
        if (function.var_is_lexical[idx]) continue;
        if (eval_global_var_bindings and !directEvalVarDeclarationShouldCreateRef(rt, global, atom_id)) continue;
        names[out_idx] = rt.atoms.dup(atom_id);
        out_idx += 1;
    }
    for (function_decl_names) |atom_id| {
        if (atom_id == eval_ret_atom) continue;
        if (directEvalSourceHasLexicalDeclarationName(rt, source, atom_id)) continue;
        if (functionHasNonLexicalLocal(rt, function, atom_id)) continue;
        names[out_idx] = rt.atoms.dup(atom_id);
        out_idx += 1;
    }
    if (simple_var_name != core.atom.null_atom and
        simple_var_name != eval_ret_atom and
        (!eval_global_var_bindings or directEvalGlobalDataVarNeedsTemporaryRef(rt, global, simple_var_name)) and
        !functionHasNonLexicalLocal(rt, function, simple_var_name) and
        !atomSliceContains(rt, function_decl_names, simple_var_name) and
        !directEvalSourceHasLexicalDeclarationName(rt, source, simple_var_name))
    {
        names[out_idx] = rt.atoms.dup(simple_var_name);
        out_idx += 1;
    }
    return names;
}

pub fn directEvalVarNameIsNonLeadingFunctionCallerArg(
    rt: *core.JSRuntime,
    source: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    atom_id: core.Atom,
) bool {
    const function = caller_function orelse return false;
    const name = rt.atoms.name(atom_id) orelse return false;
    if (!callerFunctionHasArg(rt, function, name)) return false;
    const first = skipAsciiWhitespace(source, 0);
    if (startsWithKeyword(source[first..], "function")) return false;

    var search_start: usize = 0;
    while (std.mem.indexOf(u8, source[search_start..], "function")) |rel| {
        const idx = search_start + rel;
        if (idx > 0) {
            const prev = source[idx - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '$') {
                search_start = idx + "function".len;
                continue;
            }
        }
        var cursor = skipAsciiWhitespace(source, idx + "function".len);
        if (cursor < source.len and source[cursor] == '*') {
            cursor = skipAsciiWhitespace(source, cursor + 1);
        }
        if (source.len >= cursor + name.len and std.mem.eql(u8, source[cursor..][0..name.len], name)) {
            const after = cursor + name.len;
            if (after >= source.len or source[after] == '(' or std.ascii.isWhitespace(source[after])) return true;
        }
        search_start = idx + "function".len;
    }
    return false;
}

pub fn directEvalSourceHasLexicalDeclarationName(rt: *core.JSRuntime, source: []const u8, atom_id: core.Atom) bool {
    const name = rt.atoms.name(atom_id) orelse return false;
    var search_start: usize = 0;
    while (search_start < source.len) {
        const let_pos = std.mem.indexOf(u8, source[search_start..], "let");
        const const_pos = std.mem.indexOf(u8, source[search_start..], "const");
        const class_pos = std.mem.indexOf(u8, source[search_start..], "class");
        const rel = minOptionalIndex(let_pos, const_pos, class_pos) orelse return false;
        const keyword_index = search_start + rel.index;
        if (!looksLikeIdentifierKeyword(source, keyword_index, rel.keyword)) {
            search_start = keyword_index + rel.keyword.len;
            continue;
        }
        const cursor = skipAsciiWhitespace(source, keyword_index + rel.keyword.len);
        if (source.len >= cursor + name.len and std.mem.eql(u8, source[cursor..][0..name.len], name)) {
            const after = cursor + name.len;
            if (after >= source.len or !isIdentifierPartByte(source[after])) return true;
        }
        search_start = keyword_index + rel.keyword.len;
    }
    return false;
}

pub fn minOptionalIndex(let_pos: ?usize, const_pos: ?usize, class_pos: ?usize) ?KeywordMatch {
    var best: ?KeywordMatch = null;
    if (let_pos) |index| best = .{ .index = index, .keyword = "let" };
    if (const_pos) |index| {
        if (best == null or index < best.?.index) best = .{ .index = index, .keyword = "const" };
    }
    if (class_pos) |index| {
        if (best == null or index < best.?.index) best = .{ .index = index, .keyword = "class" };
    }
    return best;
}

pub fn looksLikeIdentifierKeyword(source: []const u8, keyword_index: usize, keyword: []const u8) bool {
    if (keyword_index > 0 and isIdentifierPartByte(source[keyword_index - 1])) return false;
    const after = keyword_index + keyword.len;
    if (after < source.len and isIdentifierPartByte(source[after])) return false;
    return true;
}

pub fn functionHasNonLexicalLocal(rt: *core.JSRuntime, function: *const bytecode.Bytecode, atom_id: core.Atom) bool {
    const local_count = @min(function.var_names.len, function.var_is_lexical.len);
    for (function.var_names[0..local_count], 0..) |name, idx| {
        if (atomIdOrNameEql(rt, name, atom_id) and !function.var_is_lexical[idx]) return true;
    }
    return false;
}

pub fn publishDirectEvalVarRefs(
    ctx: *core.JSContext,
    global: *core.Object,
    caller_frame: ?*frame_mod.Frame,
    names: []const core.Atom,
    refs: []const core.JSValue,
    eval_in_parameter_initializer: bool,
    eval_global_var_bindings: bool,
) !void {
    const count = @min(names.len, refs.len);
    if (count == 0) return;
    if (!eval_global_var_bindings) {
        if (caller_frame) |frame| {
            if (objectFromValue(frame.current_function)) |function_object| {
                var index: usize = 0;
                while (index < count) : (index += 1) {
                    try appendFunctionEvalLocal(ctx, function_object, names[index], refs[index]);
                    if (!eval_in_parameter_initializer) {
                        replaceFrameVarRefBinding(ctx.runtime, frame, names[index], refs[index]);
                    }
                }
                frame.eval_var_ref_names = function_object.functionEvalLocalNamesSlot().*;
                frame.eval_var_refs = function_object.functionEvalLocalRefsSlot().*;
                frame.eval_var_refs_republished = true;
            }
        }
        return;
    }
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const value = if (varRefCellFromValue(refs[index])) |cell|
            if (cell.varRefValueSlot().*) |stored| stored.dup() else core.JSValue.undefinedValue()
        else
            refs[index].dup();
        defer value.free(ctx.runtime);
        if (directEvalGlobalVarPublishBlocked(ctx.runtime, global, names[index])) continue;
        try defineGlobalFunctionBindingValue(ctx.runtime, global, names[index], value, true);
    }
}

pub fn directEvalGlobalVarPublishBlocked(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) bool {
    const desc = global.getOwnProperty(atom_id) orelse return false;
    defer desc.destroy(rt);
    return switch (desc.kind) {
        .generic => false,
        .data => desc.writable != true,
        .accessor => desc.setter.isUndefined(),
    };
}

pub fn directEvalVarDeclarationShouldCreateRef(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) bool {
    const desc = global.getOwnProperty(atom_id) orelse return true;
    defer desc.destroy(rt);
    return desc.kind != .accessor;
}

pub fn directEvalGlobalDataVarNeedsTemporaryRef(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) bool {
    const desc = global.getOwnProperty(atom_id) orelse return false;
    defer desc.destroy(rt);
    return desc.kind == .data and desc.writable != true;
}

pub const WorkerMessage = union(enum) {
    undefined,
    null,
    boolean: bool,
    int32: i32,
    float64: f64,
    string: []u8,
    shared_array_buffer: struct {
        store: *core.object.SharedBufferStore,
        max_byte_length: ?usize,
    },

    pub fn deinit(self: WorkerMessage, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |bytes| allocator.free(bytes),
            .shared_array_buffer => |entry| entry.store.release(),
            else => {},
        }
    }
};

pub const QjsWorker = struct {
    id: i32,
    path: []u8,
    owner_runtime: *core.JSRuntime,
    object: ?core.JSValue = null,
    to_worker: []WorkerMessage = &.{},
    to_worker_capacity: usize = 0,
    to_parent: []WorkerMessage = &.{},
    to_parent_capacity: usize = 0,
    closing: bool = false,
    done: bool = false,
};

pub const WorkerPostTarget = enum(i32) {
    worker = 1,
    parent = 2,
};

pub const QjsWorkerCoordinator = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    next_id: i32 = 1,
    workers: []*QjsWorker = &.{},
    workers_capacity: usize = 0,
};

pub var qjs_workers = QjsWorkerCoordinator{};
pub threadlocal var current_qjs_worker: ?*QjsWorker = null;
pub threadlocal var current_qjs_worker_parent: ?core.JSValue = null;

pub fn qjsWorkerIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn createOsModuleNativeFunction(rt: *core.JSRuntime, name: []const u8) ?core.JSValue {
    if (std.mem.eql(u8, name, "Worker")) return qjsWorkerNativeFunction(rt, "Worker", 1, null) catch null;
    if (std.mem.eql(u8, name, "poll")) return qjsWorkerNativeFunction(rt, "poll", 0, null) catch null;
    if (std.mem.eql(u8, name, "sleep")) return qjsWorkerNativeFunction(rt, "sleep", 1, null) catch null;
    return null;
}

pub fn qjsWorkerNativeFunction(rt: *core.JSRuntime, name: []const u8, length: i32, post_target: ?WorkerPostTarget) WorkerObjectInitError!core.JSValue {
    const value = try builtins.function.nativeFunction(rt, name, length);
    errdefer value.free(rt);
    if (objectFromValue(value)) |object| {
        if (post_target) |target| object.functionWorkerPostTargetSlot().* = @intCast(@intFromEnum(target));
        if (current_qjs_worker != null and std.mem.eql(u8, name, "Worker")) {
            const parent = try qjsWorkerParentObject(rt);
            defer parent.free(rt);
            try defineValueProperty(rt, object, "parent", parent);
        }
    }
    return value;
}

pub fn qjsWorkerFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    _ = output;
    _ = global;
    if (current_qjs_worker != null) return error.TypeError;
    if (args.len == 0 or !args[0].isString()) return error.TypeError;
    var path_bytes = std.ArrayList(u8).empty;
    defer path_bytes.deinit(ctx.runtime.memory.allocator);
    try appendSourceStringUtf8(ctx.runtime, &path_bytes, args[0]);

    const allocator = workerPageAllocator();
    const worker = try allocator.create(QjsWorker);
    var raw_worker_owned = true;
    errdefer if (raw_worker_owned) allocator.destroy(worker);
    const owned_path = try allocator.dupe(u8, path_bytes.items);
    var raw_path_owned = true;
    errdefer if (raw_path_owned) allocator.free(owned_path);

    const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);

    const worker_id = blk: {
        const io = qjsWorkerIo();
        qjs_workers.mutex.lockUncancelable(io);
        defer qjs_workers.mutex.unlock(io);
        const id = qjs_workers.next_id;
        qjs_workers.next_id += 1;
        break :blk id;
    };
    worker.* = .{
        .id = worker_id,
        .path = owned_path,
        .owner_runtime = ctx.runtime,
    };
    raw_path_owned = false;
    raw_worker_owned = false;
    var worker_record_owned = true;
    errdefer if (worker_record_owned) qjsWorkerDestroyRecord(worker);
    var worker_registered = false;
    errdefer if (worker_registered) qjsWorkerRemoveRecord(worker);

    {
        const io = qjsWorkerIo();
        qjs_workers.mutex.lockUncancelable(io);
        errdefer qjs_workers.mutex.unlock(io);
        try qjsWorkerEnsureRecordCapacity(qjs_workers.workers.len + 1);
        qjs_workers.workers = qjs_workers.workers.ptr[0 .. qjs_workers.workers.len + 1];
        qjs_workers.workers[qjs_workers.workers.len - 1] = worker;
        worker_registered = true;
        qjs_workers.mutex.unlock(io);
    }

    (try object.workerIdSlot(ctx.runtime)).* = worker_id;
    const post = try qjsWorkerNativeFunction(ctx.runtime, "postMessage", 1, .worker);
    defer post.free(ctx.runtime);
    try defineValueProperty(ctx.runtime, object, "postMessage", post);
    try defineValueProperty(ctx.runtime, object, "onmessage", core.JSValue.nullValue());
    worker.object = object.value().dup();

    const thread = try std.Thread.spawn(.{}, qjsWorkerThreadMain, .{worker});
    thread.detach();
    worker_record_owned = false;
    worker_registered = false;
    return object.value();
}

pub fn qjsWorkerCloseRecord(worker: *QjsWorker, wait: bool) void {
    const io = qjsWorkerIo();
    qjs_workers.mutex.lockUncancelable(io);
    worker.closing = true;
    qjs_workers.cond.broadcast(io);
    while (wait and !worker.done) qjs_workers.cond.waitUncancelable(io, &qjs_workers.mutex);
    qjs_workers.mutex.unlock(io);
}

pub fn cleanupWorkersForRuntime(rt: *core.JSRuntime) void {
    const io = qjsWorkerIo();

    qjs_workers.mutex.lockUncancelable(io);
    for (qjs_workers.workers) |worker| {
        if (worker.owner_runtime != rt) continue;
        worker.closing = true;
    }
    qjs_workers.cond.broadcast(io);
    qjs_workers.mutex.unlock(io);

    while (true) {
        qjs_workers.mutex.lockUncancelable(io);
        var target: ?*QjsWorker = null;
        for (qjs_workers.workers) |worker| {
            if (worker.owner_runtime != rt) continue;
            target = worker;
            break;
        }
        qjs_workers.mutex.unlock(io);
        const worker = target orelse break;

        qjsWorkerCloseRecord(worker, true);

        qjs_workers.mutex.lockUncancelable(io);
        var index: usize = 0;
        while (index < qjs_workers.workers.len) : (index += 1) {
            if (qjs_workers.workers[index] != worker) continue;
            qjsWorkerRemoveRecordAtLocked(index);
            break;
        }
        qjs_workers.mutex.unlock(io);

        qjsWorkerDestroyRecord(worker);
    }
}

pub fn qjsWorkerDestroyRecord(worker: *QjsWorker) void {
    const allocator = workerPageAllocator();
    allocator.free(worker.path);
    qjsWorkerFreeMessageQueue(allocator, worker.to_worker, worker.to_worker_capacity);
    qjsWorkerFreeMessageQueue(allocator, worker.to_parent, worker.to_parent_capacity);
    if (worker.object) |value| value.free(worker.owner_runtime);
    allocator.destroy(worker);
}

pub fn qjsWorkerThreadMain(worker: *QjsWorker) void {
    current_qjs_worker = worker;
    defer {
        current_qjs_worker = null;
    }
    defer {
        const io = qjsWorkerIo();
        qjs_workers.mutex.lockUncancelable(io);
        worker.done = true;
        qjs_workers.cond.broadcast(io);
        qjs_workers.mutex.unlock(io);
    }

    const allocator = workerPageAllocator();
    const rt = core.JSRuntime.create(allocator) catch return;
    defer rt.destroy();
    defer {
        if (current_qjs_worker_parent) |parent| {
            rt.unregisterExternalValueSymbolRoot(parent);
            parent.free(rt);
            current_qjs_worker_parent = null;
        }
    }
    rt.setCanBlock(true);
    const ctx = core.JSContext.create(rt) catch return;
    defer ctx.destroy();
    defer zjs_vm.cleanupAtomicsWaitersForContext(ctx);
    const global = zjs_vm.contextGlobal(ctx) catch return;
    const parent = qjsWorkerParentObject(rt) catch return;
    defer parent.free(rt);
    const worker_ns = core.Object.create(rt, core.class.ids.object, null) catch return;
    defer worker_ns.value().free(rt);
    defineValueProperty(rt, worker_ns, "parent", parent) catch return;
    defineValueProperty(rt, global, "Worker", worker_ns.value()) catch return;

    const io = qjsWorkerIo();
    const source = std.Io.Dir.cwd().readFileAlloc(io, worker.path, allocator, .limited(64 * 1024 * 1024)) catch return;
    defer allocator.free(source);
    const result = qjsWorkerEvalModuleGraph(ctx, global, source, worker.path, io, allocator, 64 * 1024 * 1024) catch return;
    result.free(rt);

    while (!qjsWorkerShouldClose(worker)) {
        const delivered = qjsWorkerDispatchOne(ctx, null, global, parent, .worker) catch false;
        drainPendingPromiseJobs(ctx, null, global) catch return;
        if (!delivered) std.Io.sleep(qjsWorkerIo(), std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
}

pub const WorkerModuleEvalStep = union(enum) {
    completed: core.JSValue,
    suspended: struct {
        continuation: core.JSValue,
        awaited: core.JSValue,
    },
};

pub fn qjsWorkerRegisterModuleEvalStepSymbolRoots(rt: *core.JSRuntime, step: WorkerModuleEvalStep) !u2 {
    var mask: u2 = 0;
    errdefer qjsWorkerUnregisterModuleEvalStepSymbolRoots(rt, step, mask);
    switch (step) {
        .completed => |value| {
            if (try rt.registerExternalValueSymbolRoot(value)) mask |= 0b01;
        },
        .suspended => |suspended| {
            if (try rt.registerExternalValueSymbolRoot(suspended.continuation)) mask |= 0b01;
            if (try rt.registerExternalValueSymbolRoot(suspended.awaited)) mask |= 0b10;
        },
    }
    return mask;
}

pub fn qjsWorkerUnregisterModuleEvalStepSymbolRoots(rt: *core.JSRuntime, step: WorkerModuleEvalStep, mask: u2) void {
    switch (step) {
        .completed => |value| {
            if ((mask & 0b01) != 0) rt.unregisterExternalValueSymbolRoot(value);
        },
        .suspended => |suspended| {
            if ((mask & 0b01) != 0) rt.unregisterExternalValueSymbolRoot(suspended.continuation);
            if ((mask & 0b10) != 0) rt.unregisterExternalValueSymbolRoot(suspended.awaited);
        },
    }
}

test "WorkerModuleEvalStep roots direct symbol values until unregister" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const completed_symbol = try rt.atoms.newValueSymbol("gc-worker-step-completed-symbol");
    const completed_step = WorkerModuleEvalStep{ .completed = core.JSValue.symbol(completed_symbol) };
    const completed_mask = try qjsWorkerRegisterModuleEvalStepSymbolRoots(rt, completed_step);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(completed_symbol) != null);
    qjsWorkerUnregisterModuleEvalStepSymbolRoots(rt, completed_step, completed_mask);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(completed_symbol) == null);

    const continuation_symbol = try rt.atoms.newValueSymbol("gc-worker-step-continuation-symbol");
    const awaited_symbol = try rt.atoms.newValueSymbol("gc-worker-step-awaited-symbol");
    const suspended_step = WorkerModuleEvalStep{ .suspended = .{
        .continuation = core.JSValue.symbol(continuation_symbol),
        .awaited = core.JSValue.symbol(awaited_symbol),
    } };
    const suspended_mask = try qjsWorkerRegisterModuleEvalStepSymbolRoots(rt, suspended_step);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(continuation_symbol) != null);
    try std.testing.expect(rt.atoms.name(awaited_symbol) != null);
    qjsWorkerUnregisterModuleEvalStepSymbolRoots(rt, suspended_step, suspended_mask);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(continuation_symbol) == null);
    try std.testing.expect(rt.atoms.name(awaited_symbol) == null);
}

pub const WorkerModuleContinuation = struct {
    source: []const u8,
    path: []const u8,
    continuation: core.JSValue,
    awaited: core.JSValue,
    keep_result: bool,
    completed: bool = false,
    symbol_root_mask: u2 = 0,

    pub fn registerSymbolRoots(self: *WorkerModuleContinuation, rt: *core.JSRuntime) !void {
        std.debug.assert(self.symbol_root_mask == 0);
        errdefer self.unregisterSymbolRoots(rt);
        if (try rt.registerExternalValueSymbolRoot(self.continuation)) self.symbol_root_mask |= 0b01;
        if (try rt.registerExternalValueSymbolRoot(self.awaited)) self.symbol_root_mask |= 0b10;
    }

    pub fn unregisterSymbolRoots(self: *WorkerModuleContinuation, rt: *core.JSRuntime) void {
        if ((self.symbol_root_mask & 0b01) != 0) rt.unregisterExternalValueSymbolRoot(self.continuation);
        if ((self.symbol_root_mask & 0b10) != 0) rt.unregisterExternalValueSymbolRoot(self.awaited);
        self.symbol_root_mask = 0;
    }
};

pub fn qjsWorkerEvalModuleGraph(
    ctx: *core.JSContext,
    global: *core.Object,
    source_text: []const u8,
    filename: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
) !core.JSValue {
    const normalized_filename = try std.fs.path.resolve(allocator, &.{filename});
    defer allocator.free(normalized_filename);

    var module_postorder = std.ArrayList([]const u8).empty;
    defer {
        for (module_postorder.items) |path| allocator.free(path);
        module_postorder.deinit(allocator);
    }
    try module_mod.preloadFileModuleGraphWithOrder(io, allocator, ctx.runtime, ctx, source_text, normalized_filename, max_source_size, &module_postorder);
    const root_module_name = try ctx.runtime.internAtom(normalized_filename);
    defer ctx.runtime.atoms.free(root_module_name);
    ctx.runtime.modules.linkModule(ctx.runtime, root_module_name) catch |err| return qjsWorkerModuleResolutionError(err);
    try qjsWorkerInitializeSyntheticFileModules(ctx, global, io, allocator, max_source_size);
    try qjsWorkerInitializePreloadedModuleFunctionDeclarations(ctx, global, source_text, normalized_filename, io, allocator, max_source_size, module_postorder.items);

    var continuations = std.ArrayList(WorkerModuleContinuation).empty;
    defer qjsWorkerFreeModuleContinuations(ctx.runtime, allocator, &continuations);
    for (module_postorder.items) |path| {
        if (std.mem.eql(u8, path, normalized_filename)) continue;
        try qjsWorkerDrainModuleContinuationsForDependencies(ctx, global, null, allocator, &continuations, path);
        const dep_source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
        defer allocator.free(dep_source);
        const dep_step = try qjsWorkerEvalPreloadedFileModuleStep(ctx, null, dep_source, path, null, null);
        try qjsWorkerHandleModuleEvalStep(ctx.runtime, allocator, &continuations, dep_step, dep_source, path, false);
        try drainPendingPromiseJobs(ctx, null, global);
        if (ctx.hasException()) return error.UnhandledPromiseRejection;
    }
    try qjsWorkerDrainModuleContinuationsForDependencies(ctx, global, null, allocator, &continuations, normalized_filename);
    const root_step = try qjsWorkerEvalPreloadedFileModuleStep(ctx, null, source_text, normalized_filename, null, null);
    try qjsWorkerHandleModuleEvalStep(ctx.runtime, allocator, &continuations, root_step, source_text, normalized_filename, true);
    return qjsWorkerDrainModuleContinuations(ctx, global, null, allocator, &continuations);
}

pub fn qjsWorkerInitializePreloadedModuleFunctionDeclarations(
    ctx: *core.JSContext,
    global: *core.Object,
    root_source: []const u8,
    root_path: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
    postorder: []const []const u8,
) !void {
    for (postorder) |path| {
        const module_source = if (std.mem.eql(u8, path, root_path))
            root_source
        else
            try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_size));
        defer if (!std.mem.eql(u8, path, root_path)) allocator.free(module_source);

        var compiled = try frontend.parser.parse(ctx.runtime, module_source, .{ .mode = .module, .filename = path });
        defer compiled.deinit();
        if (compiled.syntax_error) |err| {
            if (!@import("builtin").is_test) std.debug.print("SYNTAX ERROR in qjsWorkerInitializePreloadedModuleFunctionDeclarations {s}:{d}:{d} - {s}\n", .{ path, err.position.line, err.position.column, err.message });
            return error.SyntaxError;
        }
        const module_name = try ctx.runtime.internAtom(path);
        defer ctx.runtime.atoms.free(module_name);
        try module_mod.initializeModuleFunctionDeclarations(ctx, global, module_name, &compiled.function);
    }
}

pub fn qjsWorkerInitializeSyntheticFileModules(
    ctx: *core.JSContext,
    global: *core.Object,
    io: std.Io,
    allocator: std.mem.Allocator,
    max_source_size: usize,
) !void {
    for (ctx.runtime.modules.modules) |record| {
        if (record.synthetic_kind == .none) continue;
        const path = ctx.runtime.atoms.name(record.module_name) orelse return error.InvalidAtom;
        const source_path = module_mod.syntheticModuleFilePath(path);
        const module_source = try std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(max_source_size));
        defer allocator.free(module_source);
        _ = try module_mod.initializeSyntheticFileModule(ctx, global, record.module_name, module_source);
    }
}

pub fn qjsWorkerEvalPreloadedFileModuleStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    source_text: []const u8,
    filename: []const u8,
    continuation_value: ?core.JSValue,
    resume_value: ?core.JSValue,
) !WorkerModuleEvalStep {
    var input_continuation = continuation_value;
    errdefer if (input_continuation) |value| value.free(ctx.runtime);

    var compiled = try frontend.parser.parse(ctx.runtime, source_text, .{ .mode = .module, .filename = filename });
    defer compiled.deinit();
    if (compiled.syntax_error) |err| {
        if (!@import("builtin").is_test) std.debug.print("SYNTAX ERROR in {s}:{d}:{d} - {s}\n", .{ filename, err.position.line, err.position.column, err.message });
        return error.SyntaxError;
    }

    const module_name = try ctx.runtime.internAtom(filename);
    defer ctx.runtime.atoms.free(module_name);
    if (ctx.runtime.modules.find(module_name) == null) return error.ModuleNotFound;
    ctx.runtime.modules.linkModule(ctx.runtime, module_name) catch |err| return qjsWorkerModuleResolutionError(err);

    var module_var_refs = try module_mod.buildModuleVarRefs(ctx, module_name, &compiled.function);
    defer module_mod.freeModuleVarRefs(ctx.runtime, module_var_refs);
    var module_var_refs_root = ValueSliceRoot{};
    module_var_refs_root.init(ctx.runtime, &module_var_refs);
    defer module_var_refs_root.deinit();
    var owned_continuation = if (input_continuation) |value| blk: {
        input_continuation = null;
        break :blk value;
    } else blk: {
        const object = try core.Object.create(ctx.runtime, core.class.ids.generator, null);
        break :blk object.value();
    };
    errdefer owned_continuation.free(ctx.runtime);
    const continuation = try property_ops.expectObject(owned_continuation);
    var stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.stack_limit);
    defer stack.deinit(ctx.runtime);
    const result = zjs_vm.runModuleWithOutputAndVarRefsState(ctx, &stack, &compiled.function, output, module_var_refs, continuation, resume_value) catch |err| return qjsWorkerModuleResolutionError(err);
    if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
        return .{ .suspended = .{
            .continuation = owned_continuation,
            .awaited = result,
        } };
    }
    owned_continuation.free(ctx.runtime);
    return .{ .completed = result };
}

pub fn qjsWorkerHandleModuleEvalStep(
    rt: *core.JSRuntime,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(WorkerModuleContinuation),
    step: WorkerModuleEvalStep,
    source_text: []const u8,
    filename: []const u8,
    keep_result: bool,
) !void {
    switch (step) {
        .completed => |value| {
            if (keep_result) {
                errdefer value.free(rt);
                const source_copy = try allocator.dupe(u8, source_text);
                errdefer allocator.free(source_copy);
                const path_copy = try allocator.dupe(u8, filename);
                errdefer allocator.free(path_copy);
                var continuation = WorkerModuleContinuation{
                    .source = source_copy,
                    .path = path_copy,
                    .continuation = core.JSValue.undefinedValue(),
                    .awaited = value,
                    .keep_result = true,
                    .completed = true,
                };
                try continuation.registerSymbolRoots(rt);
                errdefer continuation.unregisterSymbolRoots(rt);
                try continuations.append(allocator, continuation);
            } else {
                value.free(rt);
            }
        },
        .suspended => |suspended| {
            errdefer suspended.continuation.free(rt);
            errdefer suspended.awaited.free(rt);
            const source_copy = try allocator.dupe(u8, source_text);
            errdefer allocator.free(source_copy);
            const path_copy = try allocator.dupe(u8, filename);
            errdefer allocator.free(path_copy);
            var continuation = WorkerModuleContinuation{
                .source = source_copy,
                .path = path_copy,
                .continuation = suspended.continuation,
                .awaited = suspended.awaited,
                .keep_result = keep_result,
            };
            try continuation.registerSymbolRoots(rt);
            errdefer continuation.unregisterSymbolRoots(rt);
            try continuations.append(allocator, continuation);
        },
    }
}

pub fn qjsWorkerDrainModuleContinuations(
    ctx: *core.JSContext,
    global: *core.Object,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(WorkerModuleContinuation),
) !core.JSValue {
    var kept_result: core.JSValue = core.JSValue.undefinedValue();
    var has_kept_result = false;
    var kept_result_symbol_rooted = false;
    errdefer if (has_kept_result) kept_result.free(ctx.runtime);
    defer if (kept_result_symbol_rooted) ctx.runtime.unregisterExternalValueSymbolRoot(kept_result);
    while (continuations.items.len != 0) {
        if (try qjsWorkerDrainOneModuleContinuation(ctx, global, output, allocator, continuations)) |value| {
            errdefer value.free(ctx.runtime);
            const value_symbol_rooted = try ctx.runtime.registerExternalValueSymbolRoot(value);
            if (has_kept_result) {
                if (kept_result_symbol_rooted) ctx.runtime.unregisterExternalValueSymbolRoot(kept_result);
                kept_result_symbol_rooted = false;
                kept_result.free(ctx.runtime);
            }
            kept_result = value;
            kept_result_symbol_rooted = value_symbol_rooted;
            has_kept_result = true;
        }
    }
    if (has_kept_result) return kept_result;
    return core.JSValue.undefinedValue();
}

pub fn qjsWorkerDrainModuleContinuationsForDependencies(
    ctx: *core.JSContext,
    global: *core.Object,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(WorkerModuleContinuation),
    filename: []const u8,
) !void {
    while (try qjsWorkerHasActiveAsyncDependency(ctx, continuations, filename)) {
        if (try qjsWorkerDrainOneModuleContinuation(ctx, global, output, allocator, continuations)) |value| value.free(ctx.runtime);
    }
}

pub fn qjsWorkerDrainOneModuleContinuation(
    ctx: *core.JSContext,
    global: *core.Object,
    output: ?*std.Io.Writer,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(WorkerModuleContinuation),
) !?core.JSValue {
    var current = continuations.orderedRemove(0);
    var current_roots_registered = true;
    errdefer if (current_roots_registered) current.unregisterSymbolRoots(ctx.runtime);
    defer allocator.free(current.source);
    defer allocator.free(current.path);
    if (current.completed) {
        current.unregisterSymbolRoots(ctx.runtime);
        current_roots_registered = false;
        if (current.keep_result) return current.awaited;
        current.awaited.free(ctx.runtime);
        return null;
    }
    const awaited_value = current.awaited;
    var awaited_owned = true;
    errdefer if (awaited_owned) awaited_value.free(ctx.runtime);
    const continuation = current.continuation;
    var continuation_owned = true;
    errdefer if (continuation_owned) continuation.free(ctx.runtime);
    const module_source = current.source;
    const path = current.path;
    const keep_result = current.keep_result;
    try drainPendingPromiseJobs(ctx, output, global);
    continuation_owned = false;
    const step = try qjsWorkerEvalPreloadedFileModuleStep(ctx, output, module_source, path, continuation, awaited_value);
    awaited_value.free(ctx.runtime);
    awaited_owned = false;
    current.unregisterSymbolRoots(ctx.runtime);
    current_roots_registered = false;
    var step_owned = true;
    errdefer if (step_owned) qjsWorkerFreeModuleEvalStep(ctx.runtime, step);
    const step_symbol_root_mask = try qjsWorkerRegisterModuleEvalStepSymbolRoots(ctx.runtime, step);
    var step_roots_registered = true;
    errdefer if (step_roots_registered) qjsWorkerUnregisterModuleEvalStepSymbolRoots(ctx.runtime, step, step_symbol_root_mask);
    try drainPendingPromiseJobs(ctx, output, global);
    if (ctx.hasException()) return error.UnhandledPromiseRejection;
    qjsWorkerUnregisterModuleEvalStepSymbolRoots(ctx.runtime, step, step_symbol_root_mask);
    step_roots_registered = false;
    step_owned = false;
    try qjsWorkerHandleModuleEvalStep(ctx.runtime, allocator, continuations, step, module_source, path, keep_result);
    return null;
}

pub fn qjsWorkerFreeModuleContinuations(
    rt: *core.JSRuntime,
    allocator: std.mem.Allocator,
    continuations: *std.ArrayList(WorkerModuleContinuation),
) void {
    for (continuations.items) |*entry| {
        allocator.free(entry.source);
        allocator.free(entry.path);
        entry.unregisterSymbolRoots(rt);
        if (!entry.completed) entry.continuation.free(rt);
        entry.awaited.free(rt);
    }
    continuations.deinit(allocator);
}

pub fn qjsWorkerFreeModuleEvalStep(rt: *core.JSRuntime, step: WorkerModuleEvalStep) void {
    switch (step) {
        .completed => |value| value.free(rt),
        .suspended => |suspended| {
            suspended.continuation.free(rt);
            suspended.awaited.free(rt);
        },
    }
}

pub fn qjsWorkerModuleResolutionError(err: anytype) (@TypeOf(err) || error{SyntaxError}) {
    if (err == error.MissingExport or err == error.AmbiguousExport) {
        std.debug.print("LINK ERROR in qjsWorkerModuleResolutionError: {s}\n", .{@errorName(err)});
    }
    return switch (err) {
        error.MissingExport, error.AmbiguousExport => error.SyntaxError,
        else => err,
    };
}

pub fn qjsWorkerShouldClose(worker: *QjsWorker) bool {
    const io = qjsWorkerIo();
    qjs_workers.mutex.lockUncancelable(io);
    defer qjs_workers.mutex.unlock(io);
    return worker.closing;
}

pub fn qjsWorkerPostMessage(ctx: *core.JSContext, this_value: core.JSValue, args: []const core.JSValue, target: WorkerPostTarget) !core.JSValue {
    var rooted_this = this_value;
    var rooted_payload = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_this },
        .{ .value = &rooted_payload },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const worker_id = try qjsWorkerObjectId(ctx.runtime, rooted_this);
    const payload = try qjsWorkerMessageFromValue(ctx.runtime, rooted_payload);
    errdefer payload.deinit(workerPageAllocator());
    const io = qjsWorkerIo();
    qjs_workers.mutex.lockUncancelable(io);
    defer qjs_workers.mutex.unlock(io);
    const worker = qjsWorkerByIdLocked(worker_id) orelse return error.TypeError;
    const queue = switch (target) {
        .worker => &worker.to_worker,
        .parent => &worker.to_parent,
    };
    const capacity = switch (target) {
        .worker => &worker.to_worker_capacity,
        .parent => &worker.to_parent_capacity,
    };
    try qjsWorkerAppendMessage(queue, capacity, payload);
    qjs_workers.cond.broadcast(io);
    return core.JSValue.undefinedValue();
}

pub fn qjsWorkerPoll(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !core.JSValue {
    var delivered: i32 = 0;
    while (try qjsWorkerDispatchAnyForRuntime(ctx, output, global)) delivered += 1;
    return core.JSValue.int32(delivered);
}

pub fn qjsWorkerSleep(args: []const core.JSValue) !core.JSValue {
    const value = if (args.len >= 1) args[0] else core.JSValue.int32(0);
    const number = value_ops.numberValue(value) orelse 0;
    if (number > 0) {
        const ms: i64 = @intFromFloat(@min(number, 60_000));
        std.Io.sleep(qjsWorkerIo(), std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
    }
    return core.JSValue.undefinedValue();
}

pub fn qjsWorkerDispatchAnyForRuntime(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) !bool {
    const io = qjsWorkerIo();
    qjs_workers.mutex.lockUncancelable(io);
    var selected: ?*QjsWorker = null;
    var object_value: core.JSValue = core.JSValue.undefinedValue();
    for (qjs_workers.workers) |worker| {
        if (worker.owner_runtime != ctx.runtime or worker.to_parent.len == 0) continue;
        if (worker.object) |stored| {
            object_value = stored.dup();
            selected = worker;
            break;
        }
    }
    qjs_workers.mutex.unlock(io);
    if (selected == null) return false;
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return false;
    const handler_key = try ctx.runtime.internAtom("onmessage");
    defer ctx.runtime.atoms.free(handler_key);
    const handler = object.getProperty(handler_key);
    if (!isCallableValue(handler)) {
        handler.free(ctx.runtime);
        return false;
    }
    handler.free(ctx.runtime);
    return qjsWorkerDispatchOne(ctx, output, global, object_value, .parent);
}

pub fn qjsWorkerDispatchOne(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, endpoint_value: core.JSValue, endpoint: WorkerPostTarget) !bool {
    var rooted_endpoint_value = endpoint_value;
    var handler = core.JSValue.undefinedValue();
    var data = core.JSValue.undefinedValue();
    var event_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_endpoint_value },
        .{ .value = &handler },
        .{ .value = &data },
        .{ .value = &event_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const endpoint_object = objectFromValue(rooted_endpoint_value) orelse return false;
    const handler_key = try ctx.runtime.internAtom("onmessage");
    defer ctx.runtime.atoms.free(handler_key);
    handler = endpoint_object.getProperty(handler_key);
    defer {
        const owned_handler = handler;
        handler = core.JSValue.undefinedValue();
        owned_handler.free(ctx.runtime);
    }
    if (!isCallableValue(handler)) return false;
    const worker_id = try qjsWorkerObjectId(ctx.runtime, rooted_endpoint_value);
    const message = qjsWorkerPopMessage(worker_id, endpoint) orelse return false;
    defer message.deinit(workerPageAllocator());
    data = try qjsWorkerMessageToValue(ctx.runtime, message);
    defer {
        const owned_data = data;
        data = core.JSValue.undefinedValue();
        owned_data.free(ctx.runtime);
    }
    const event = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    event_value = event.value();
    defer {
        const owned_event = event_value;
        event_value = core.JSValue.undefinedValue();
        owned_event.free(ctx.runtime);
    }
    try defineValueProperty(ctx.runtime, event, "data", data);
    const result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), handler, &.{event_value}, null, null);
    result.free(ctx.runtime);
    return true;
}

pub fn qjsWorkerByIdLocked(id: i32) ?*QjsWorker {
    for (qjs_workers.workers) |worker| {
        if (worker.id == id) return worker;
    }
    return null;
}

pub fn qjsWorkerEnsureRecordCapacity(min_capacity: usize) !void {
    if (qjs_workers.workers_capacity >= min_capacity) return;
    const allocator = workerPageAllocator();
    var next_capacity = if (qjs_workers.workers_capacity == 0) @as(usize, 4) else qjs_workers.workers_capacity * 2;
    while (next_capacity < min_capacity) : (next_capacity *= 2) {}
    const next = try allocator.alloc(*QjsWorker, next_capacity);
    @memcpy(next[0..qjs_workers.workers.len], qjs_workers.workers);
    if (qjs_workers.workers_capacity != 0) allocator.free(qjs_workers.workers.ptr[0..qjs_workers.workers_capacity]);
    qjs_workers.workers = next[0..qjs_workers.workers.len];
    qjs_workers.workers_capacity = next_capacity;
}

pub fn qjsWorkerRemoveRecordAtLocked(index: usize) void {
    std.debug.assert(index < qjs_workers.workers.len);
    const old_len = qjs_workers.workers.len;
    if (index + 1 < old_len) {
        @memmove(qjs_workers.workers[index .. old_len - 1], qjs_workers.workers[index + 1 .. old_len]);
    }
    qjs_workers.workers = qjs_workers.workers.ptr[0 .. old_len - 1];
    if (qjs_workers.workers.len == 0 and qjs_workers.workers_capacity != 0) {
        const allocator = workerPageAllocator();
        allocator.free(qjs_workers.workers.ptr[0..qjs_workers.workers_capacity]);
        qjs_workers.workers = &.{};
        qjs_workers.workers_capacity = 0;
    }
}

pub fn qjsWorkerRemoveRecord(worker: *QjsWorker) void {
    const io = qjsWorkerIo();
    qjs_workers.mutex.lockUncancelable(io);
    defer qjs_workers.mutex.unlock(io);
    var index: usize = 0;
    while (index < qjs_workers.workers.len) : (index += 1) {
        if (qjs_workers.workers[index] != worker) continue;
        qjsWorkerRemoveRecordAtLocked(index);
        return;
    }
}

pub fn qjsWorkerFreeMessageQueue(allocator: std.mem.Allocator, queue: []WorkerMessage, capacity: usize) void {
    for (queue) |message| message.deinit(allocator);
    if (capacity != 0) allocator.free(queue.ptr[0..capacity]);
}

pub fn qjsWorkerEnsureMessageCapacity(queue: *[]WorkerMessage, capacity: *usize, min_capacity: usize) !void {
    const allocator = workerPageAllocator();
    if (capacity.* >= min_capacity) return;
    var next_capacity = if (capacity.* == 0) @as(usize, 4) else capacity.* * 2;
    while (next_capacity < min_capacity) : (next_capacity *= 2) {}
    const next = try allocator.alloc(WorkerMessage, next_capacity);
    @memcpy(next[0..queue.*.len], queue.*);
    const old_capacity = capacity.*;
    const old = if (old_capacity != 0) queue.*.ptr[0..old_capacity] else queue.*[0..0];
    queue.* = next[0..queue.*.len];
    capacity.* = next_capacity;
    if (old_capacity != 0) allocator.free(old);
}

pub fn qjsWorkerAppendMessage(queue: *[]WorkerMessage, capacity: *usize, message: WorkerMessage) !void {
    const index = queue.*.len;
    try qjsWorkerEnsureMessageCapacity(queue, capacity, index + 1);
    queue.* = queue.*.ptr[0 .. index + 1];
    queue.*[index] = message;
}

pub fn qjsWorkerMessageFromValue(rt: *core.JSRuntime, value: core.JSValue) !WorkerMessage {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (rooted_value.isUndefined()) return .undefined;
    if (rooted_value.isNull()) return .null;
    if (rooted_value.asBool()) |bool_value| return .{ .boolean = bool_value };
    if (rooted_value.asInt32()) |int_value| return .{ .int32 = int_value };
    if (value_ops.numberValue(rooted_value)) |number| return .{ .float64 = number };
    if (rooted_value.isString()) {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try appendSourceStringUtf8(rt, &bytes, rooted_value);
        return .{ .string = try workerPageAllocator().dupe(u8, bytes.items) };
    }
    if (objectFromValue(rooted_value)) |object| {
        if (object.class_id == core.class.ids.shared_array_buffer) {
            const store = object.sharedByteStorageStore() orelse return error.TypeError;
            store.retain();
            return .{ .shared_array_buffer = .{ .store = store, .max_byte_length = object.arrayBufferMaxByteLength() } };
        }
    }
    return error.TypeError;
}

pub fn qjsWorkerMessageToValue(rt: *core.JSRuntime, message: WorkerMessage) !core.JSValue {
    return switch (message) {
        .undefined => core.JSValue.undefinedValue(),
        .null => core.JSValue.nullValue(),
        .boolean => |value| core.JSValue.boolean(value),
        .int32 => |value| core.JSValue.int32(value),
        .float64 => |value| core.JSValue.float64(value),
        .string => |bytes| value_ops.createStringValue(rt, bytes),
        .shared_array_buffer => |entry| builtins.buffer.sharedArrayBufferFromStore(rt, entry.store, entry.max_byte_length, null),
    };
}

pub fn indirectEval(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    eval_global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.undefinedValue();
    if (!args[0].isString()) return args[0].dup();
    var source = std.ArrayList(u8).empty;
    defer source.deinit(ctx.runtime.memory.allocator);
    try appendSourceStringUtf8(ctx.runtime, &source, args[0]);

    const context_global = ctx.global;
    const use_global_lexicals = context_global == null or context_global.? != eval_global;
    const saved_lexicals = ctx.lexicals;
    if (use_global_lexicals) ctx.lexicals = eval_global.global_lexicals;
    defer if (use_global_lexicals) {
        eval_global.global_lexicals = ctx.lexicals;
        ctx.lexicals = saved_lexicals;
    };

    if (try simpleEvalRegExpLiteral(ctx, eval_global, source.items)) |value| return value;
    var compiled = try frontend.parser.parse(ctx.runtime, source.items, .{ .mode = .eval_indirect, .filename = "<eval>", .strict = false });
    defer compiled.deinit();
    if (compiled.syntax_error != null) return error.SyntaxError;
    if (!compiled.function.flags.is_strict) {
        try validateGlobalEvalFunctionDeclarations(ctx, eval_global, source.items, true);
    }
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    return runWithArgsState(ctx, &nested_stack, &compiled.function, eval_global.value(), &.{}, &.{}, output, eval_global, true, false, false, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, null, null, null, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), true, true, core.JSValue.undefinedValue(), false, false) catch |err| {
        return normalizeEvalRuntimeError(err);
    };
}

pub fn simpleEvalRegExpLiteral(ctx: *core.JSContext, global: *core.Object, source: []const u8) !?core.JSValue {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return null;
    if (trimmed.len >= 2 and (trimmed[1] == '*' or trimmed[1] == '/')) return null;
    const literal = frontend.zjs_lexer.scanRegExpLiteral(trimmed, 0) catch return null;
    if (literal.end_offset != trimmed.len) return null;
    if (containsUtf8LineSeparator(literal.pattern)) return null;
    return try builtins.regexp.constructLiteral(ctx.runtime, literal.pattern, literal.flags, constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"));
}

pub fn containsUtf8LineSeparator(bytes: []const u8) bool {
    var index: usize = 0;
    while (index + 2 < bytes.len) : (index += 1) {
        if (bytes[index] == 0xe2 and bytes[index + 1] == 0x80 and
            (bytes[index + 2] == 0xa8 or bytes[index + 2] == 0xa9)) return true;
    }
    return false;
}

pub fn evalSimpleCallerExpression(
    ctx: *core.JSContext,
    source: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const frame = caller_frame orelse return null;
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (simpleEvalStringLiteral(ctx.runtime, trimmed)) |value| return value;
    if (std.mem.eql(u8, trimmed, "this")) return directEvalThisValue(ctx.runtime, caller_function, caller_frame).dup();
    if (std.mem.startsWith(u8, trimmed, "delete ")) {
        const ident = std.mem.trim(u8, trimmed["delete ".len..], " \t\r\n");
        if (isSimpleIdentifierName(ident) and callerFunctionHasBinding(ctx.runtime, caller_function, frame, ident)) {
            return core.JSValue.boolean(false);
        }
        return null;
    }
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
        const lhs = std.mem.trim(u8, trimmed[0..eq], " \t\r\n");
        const rhs = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\r\n");
        if (isSimpleIdentifierName(lhs) and isSimpleIntegerLiteral(rhs) and callerFunctionNameEql(ctx.runtime, caller_function, lhs)) {
            if (caller_function) |function| {
                if (function.flags.is_strict) return error.TypeError;
            }
            return core.JSValue.undefinedValue();
        }
    }
    return null;
}

pub fn isSimpleIdentifierName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_' or name[0] == '$')) return false;
    for (name[1..]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$')) return false;
    }
    return true;
}

pub fn isSimpleIntegerLiteral(text: []const u8) bool {
    _ = std.fmt.parseInt(i32, text, 10) catch return false;
    return true;
}

pub fn callerFunctionNameEql(rt: *core.JSRuntime, caller_function: ?*const bytecode.Bytecode, name: []const u8) bool {
    const function = caller_function orelse return false;
    const function_name = rt.atoms.name(function.name) orelse return false;
    return std.mem.eql(u8, function_name, name);
}

pub fn simpleVarDeclarationName(source: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "var ")) return null;
    const rest = std.mem.trim(u8, trimmed["var ".len..], " \t\r\n");
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_' or rest[end] == '$')) : (end += 1) {}
    if (end == 0) return null;
    const name = rest[0..end];
    const tail = std.mem.trim(u8, rest[end..], " \t\r\n");
    if (tail.len != 0 and tail[0] != '=' and tail[0] != ';') return null;
    return if (isSimpleIdentifierName(name)) name else null;
}

pub fn callerFunctionHasArg(rt: *core.JSRuntime, function: *const bytecode.Bytecode, name: []const u8) bool {
    for (function.arg_names) |atom_id| {
        const arg_name = rt.atoms.name(atom_id) orelse continue;
        if (std.mem.eql(u8, arg_name, name)) return true;
    }
    return false;
}

pub fn callerFunctionHasLexicalLocal(rt: *core.JSRuntime, function: *const bytecode.Bytecode, name: []const u8) bool {
    const local_count = @min(function.var_names.len, function.var_is_lexical.len);
    for (function.var_names[0..local_count], 0..) |atom_id, idx| {
        if (!function.var_is_lexical[idx]) continue;
        const local_name = rt.atoms.name(atom_id) orelse continue;
        if (std.mem.eql(u8, local_name, name)) return true;
    }
    return false;
}

pub fn callerFunctionHasBinding(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    name: []const u8,
) bool {
    const function = caller_function orelse return false;
    const local_count = @min(function.var_names.len, frame.locals.len);
    for (function.var_names[0..local_count]) |atom_id| {
        if (value_ops.atomNameEql(rt, atom_id, name)) return true;
    }
    const ref_count = @min(function.var_ref_names.len, frame.var_refs.len);
    for (function.var_ref_names[0..ref_count]) |atom_id| {
        if (value_ops.atomNameEql(rt, atom_id, name)) return true;
    }
    return false;
}

pub fn functionHasFrameBinding(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
) bool {
    const local_count = @min(function.var_names.len, frame.locals.len);
    for (function.var_names[0..local_count]) |binding| {
        if (binding == atom_id or atomNamesEqual(rt, binding, atom_id)) return true;
    }
    const ref_count = @min(function.var_ref_names.len, frame.var_refs.len);
    for (function.var_ref_names[0..ref_count]) |binding| {
        if (binding == atom_id or atomNamesEqual(rt, binding, atom_id)) return true;
    }
    return false;
}

pub fn atomNamesEqual(rt: *core.JSRuntime, a: core.Atom, b: core.Atom) bool {
    const a_name = rt.atoms.name(a) orelse return false;
    const b_name = rt.atoms.name(b) orelse return false;
    return std.mem.eql(u8, a_name, b_name);
}

pub const ActiveRootValueProbe = struct {
    const Mode = enum { same_value, heap_bigint };

    rt: *core.JSRuntime,
    mode: Mode = .same_value,
    target: core.JSValue = core.JSValue.undefinedValue(),
    match_count: usize = 0,
    current_match_count: usize = 0,
    max_match_count: usize = 0,
    trace_failed: bool = false,

    pub fn trigger(context: ?*anyopaque, size: usize) void {
        _ = size;
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const saved_trigger_fn = self.rt.memory.trigger_gc_fn;
        const saved_trigger_ctx = self.rt.memory.trigger_gc_ctx;
        self.rt.memory.trigger_gc_fn = null;
        self.rt.memory.trigger_gc_ctx = null;
        defer {
            self.rt.memory.trigger_gc_fn = saved_trigger_fn;
            self.rt.memory.trigger_gc_ctx = saved_trigger_ctx;
        }
        var visitor = core.runtime.RootVisitor{
            .context = self,
            .visit_value = @This().visitValue,
            .visit_object = @This().visitObject,
        };
        self.current_match_count = 0;
        self.rt.traceActiveRoots(&visitor) catch {
            self.trace_failed = true;
        };
        self.max_match_count = @max(self.max_match_count, self.current_match_count);
    }

    pub fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (self.mode) {
            .same_value => if (slot.same(self.target)) {
                self.match_count += 1;
                self.current_match_count += 1;
            },
            .heap_bigint => if (slot.isBigInt() and slot.asShortBigInt() == null) {
                self.match_count += 1;
                self.current_match_count += 1;
            },
        }
    }

    pub fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
        _ = context;
        _ = slot;
    }
};

pub fn freeArgs(rt: *core.JSRuntime, args: []core.JSValue) void {
    for (args) |arg| arg.free(rt);
    if (args.len != 0) rt.memory.free(core.JSValue, args);
}

test "argsFromArrayLike roots initialized prefix while reading source" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const source = try core.Object.create(rt, core.class.ids.object, null);
    var source_alive = true;
    defer if (source_alive) source.value().free(rt);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-args-from-array-like-prefix-root");
    try source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.symbol(symbol_atom), true, true, true));
    try source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), true, false, true));
    try source.defineAutoInitProperty(rt, core.atom.atomFromUInt32(1), "lazyArgsFromArrayLikeValue", 0, core.property.Flags.data(true, true, true));

    const Probe = struct {
        rt: *core.JSRuntime,
        atom_id: u32,
        saw_symbol: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const saved_trigger_fn = self.rt.memory.trigger_gc_fn;
            const saved_trigger_ctx = self.rt.memory.trigger_gc_ctx;
            self.rt.memory.trigger_gc_fn = null;
            self.rt.memory.trigger_gc_ctx = null;
            defer {
                self.rt.memory.trigger_gc_fn = saved_trigger_fn;
                self.rt.memory.trigger_gc_ctx = saved_trigger_ctx;
            }
            var visitor = core.runtime.RootVisitor{
                .context = self,
                .visit_value = @This().visitValue,
                .visit_object = @This().visitObject,
            };
            self.rt.traceActiveRoots(&visitor) catch {
                self.trace_failed = true;
            };
        }

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.asSymbolAtom()) |atom_id| {
                if (atom_id == self.atom_id) self.saw_symbol = true;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var probe = Probe{
        .rt = rt,
        .atom_id = symbol_atom,
    };
    rt.memory.trigger_gc_fn = Probe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    const args = try argsFromArrayLike(ctx, null, global, source.value(), null, null);
    var args_alive = true;
    defer if (args_alive) freeArgs(rt, args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.saw_symbol);

    freeArgs(rt, args);
    args_alive = false;
    source.value().free(rt);
    source_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn callFunctionBytecode(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) !core.JSValue {
    return callFunctionBytecodeMode(ctx, func, current_function_value, this_value, args, var_refs, output, global, eval_var_ref_names, eval_var_refs, true);
}

pub fn callFunctionBytecodeConstruct(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    new_target_value: core.JSValue,
    constructor_this_value: core.JSValue,
) !core.JSValue {
    return callFunctionBytecodeModeState(ctx, func, current_function_value, this_value, args, var_refs, output, global, eval_var_ref_names, eval_var_refs, true, null, null, null, new_target_value, constructor_this_value);
}

pub fn callFunctionBytecodeMode(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    defer_generators: bool,
) !core.JSValue {
    return callFunctionBytecodeModeState(ctx, func, current_function_value, this_value, args, var_refs, output, global, eval_var_ref_names, eval_var_refs, defer_generators, null, null, null, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

pub fn callFunctionBytecodeModeState(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    defer_generators: bool,
    generator_state: ?*core.Object,
    resume_value: ?core.JSValue,
    stop_before_pc: ?usize,
    new_target_value: core.JSValue,
    constructor_this_value: core.JSValue,
) HostError!core.JSValue {
    const fb = functionBytecodeFromValue(func) orelse return error.TypeError;
    if (defer_generators and (fb.func_kind == .generator or fb.func_kind == .async_generator)) {
        return createGeneratorObject(ctx, func, current_function_value, this_value, args, var_refs, output, global, eval_var_ref_names, eval_var_refs, fb.func_kind == .async_generator);
    }

    var nested = bytecode.function.asBytecodeView(fb, ctx.runtime);

    var combined_var_refs: []const core.JSValue = var_refs;
    var allocated_combined_refs: []core.JSValue = &.{};
    defer if (allocated_combined_refs.len != 0) ctx.runtime.memory.free(core.JSValue, allocated_combined_refs);
    var rooted_combined_refs: []core.JSValue = &.{};
    var combined_refs_root = ValueSliceRoot{};
    combined_refs_root.init(ctx.runtime, &rooted_combined_refs);
    defer combined_refs_root.deinit();
    var allocated_var_ref_names: []core.Atom = &.{};
    defer {
        for (allocated_var_ref_names) |atom_id| ctx.runtime.atoms.free(atom_id);
        if (allocated_var_ref_names.len != 0) ctx.runtime.memory.free(core.Atom, allocated_var_ref_names);
    }
    if (eval_var_ref_names.len > 0 and eval_var_refs.len > 0) {
        const old_name_len = nested.var_ref_names.len;
        const add_len = @min(eval_var_ref_names.len, eval_var_refs.len);
        const names = try ctx.runtime.memory.alloc(core.Atom, old_name_len + add_len);
        var names_transferred = false;
        errdefer if (!names_transferred) ctx.runtime.memory.free(core.Atom, names);
        var initialized_names: usize = 0;
        errdefer if (!names_transferred) {
            for (names[0..initialized_names]) |atom_id| ctx.runtime.atoms.free(atom_id);
        };
        for (nested.var_ref_names, 0..) |atom_id, idx| {
            names[idx] = ctx.runtime.atoms.dup(atom_id);
            initialized_names += 1;
        }
        for (eval_var_ref_names[0..add_len], 0..) |atom_id, idx| names[old_name_len + idx] = ctx.runtime.atoms.dup(atom_id);
        initialized_names += add_len;

        const refs = try ctx.runtime.memory.alloc(core.JSValue, var_refs.len + add_len);
        var refs_transferred = false;
        errdefer if (!refs_transferred) {
            rooted_combined_refs = &.{};
            ctx.runtime.memory.free(core.JSValue, refs);
        };
        for (var_refs, 0..) |value, idx| refs[idx] = value;
        for (eval_var_refs[0..add_len], 0..) |value, idx| refs[var_refs.len + idx] = value;
        rooted_combined_refs = refs;

        nested.var_ref_names = names;
        allocated_var_ref_names = names;
        names_transferred = true;
        combined_var_refs = refs;
        allocated_combined_refs = refs;
        refs_transferred = true;
    }

    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    var boxed_this: ?core.JSValue = null;
    defer if (boxed_this) |value| value.free(ctx.runtime);
    const fb_runtime_strict = fb.is_strict_mode or fb.runtime_strict_mode;
    const effective_this = if (!fb_runtime_strict) blk: {
        if (this_value.isUndefined() or this_value.isNull()) break :blk global.value();
        if (!this_value.isObject()) {
            boxed_this = try primitiveObjectForAccess(ctx.runtime, global, this_value);
            break :blk boxed_this.?;
        }
        break :blk this_value;
    } else this_value;
    if (fb.func_kind == .async and generator_state == null) {
        return qjsAsyncFunctionStart(ctx, func, current_function_value, effective_this, args, combined_var_refs, output, global, eval_var_ref_names, eval_var_refs);
    }
    const stop_on_yield = fb.func_kind == .generator or fb.func_kind == .async_generator;
    const result = runWithArgsState(ctx, &nested_stack, &nested, effective_this, args, combined_var_refs, output, global, false, fb_runtime_strict, stop_on_yield, &.{}, &.{}, eval_var_ref_names, eval_var_refs, &.{}, &.{}, &.{}, &.{}, generator_state, resume_value, stop_before_pc, current_function_value, new_target_value, constructor_this_value, false, false, core.JSValue.undefinedValue(), false, false) catch |err| {
        if (fb.func_kind == .async_generator) {
            return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
        }
        return err;
    };
    if (fb.func_kind == .async_generator) {
        defer result.free(ctx.runtime);
        return builtins.promise.fulfilledWithPrototype(ctx.runtime, result, promisePrototypeFromGlobal(ctx.runtime, global));
    }
    return result;
}

pub fn runGeneratorParameterInit(
    ctx: *core.JSContext,
    fb: *const bytecode.FunctionBytecode,
    object: *core.Object,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !core.JSValue {
    var nested = bytecode.Bytecode.init(&ctx.runtime.memory, &ctx.runtime.atoms, fb.func_name);
    defer nested.deinit(ctx.runtime);
    nested.atoms.replace(&nested.filename, fb.filename);
    nested.line_num = fb.line_num;
    nested.col_num = fb.col_num;
    nested.arg_count = fb.arg_count;
    nested.var_count = fb.var_count;
    nested.stack_size = fb.stack_size;
    nested.flags.is_strict = fb.is_strict_mode;
    nested.flags.runtime_strict = fb.runtime_strict_mode;
    nested.flags.has_simple_parameter_list = fb.has_simple_parameter_list;
    try nested.setCode(fb.byte_code);
    for (fb.atom_operands) |atom_id| {
        try nested.retainAtomOperand(atom_id);
    }
    if (fb.arg_names.len > 0) {
        nested.arg_names = try ctx.runtime.memory.alloc(core.Atom, fb.arg_names.len);
        for (fb.arg_names, 0..) |atom_id, idx| {
            nested.arg_names[idx] = ctx.runtime.atoms.dup(atom_id);
        }
    }
    if (fb.var_names.len > 0) {
        nested.var_names = try ctx.runtime.memory.alloc(core.Atom, fb.var_names.len);
        for (fb.var_names, 0..) |atom_id, idx| {
            nested.var_names[idx] = ctx.runtime.atoms.dup(atom_id);
        }
    }
    if (fb.var_is_lexical.len > 0) {
        nested.var_is_lexical = try ctx.runtime.memory.alloc(bool, fb.var_is_lexical.len);
        @memcpy(nested.var_is_lexical, fb.var_is_lexical);
    }
    if (fb.var_is_const.len > 0) {
        nested.var_is_const = try ctx.runtime.memory.alloc(bool, fb.var_is_const.len);
        @memcpy(nested.var_is_const, fb.var_is_const);
    }
    if (fb.var_ref_names.len > 0) {
        nested.var_ref_names = try ctx.runtime.memory.alloc(core.Atom, fb.var_ref_names.len);
        for (fb.var_ref_names, 0..) |atom_id, idx| {
            nested.var_ref_names[idx] = ctx.runtime.atoms.dup(atom_id);
        }
    }
    for (fb.cpool) |value| {
        _ = try nested.addConstant(value);
    }

    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);
    return runWithArgsState(ctx, &nested_stack, &nested, this_value, args, var_refs, output, global, false, true, false, &.{}, &.{}, object.functionEvalLocalNamesSlot().*, object.functionEvalLocalRefsSlot().*, &.{}, &.{}, &.{}, &.{}, object, null, fb.generator_body_pc, current_function_value, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), false, false, core.JSValue.undefinedValue(), false, false);
}

pub fn qjsGeneratorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    if (!receiver.isObject()) return null;
    const object = property_ops.expectObject(receiver) catch return null;
    if (object.class_id != core.class.ids.generator and object.class_id != core.class.ids.async_generator) return null;
    if (object.generatorExecuting()) return error.TypeError;
    const generator_global = objectRealmGlobal(object) orelse global;
    if (object.generatorDone()) {
        const done_result = try createIteratorResult(ctx.runtime, generator_global, core.JSValue.undefinedValue(), true);
        defer done_result.free(ctx.runtime);
        if (object.class_id == core.class.ids.async_generator) {
            return try builtins.promise.fulfilledWithPrototype(ctx.runtime, done_result, promisePrototypeFromGlobal(ctx.runtime, generator_global));
        }
        return done_result.dup();
    }
    const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
    const stored_current_function = if (object.generatorCurrentFunction()) |value| value.dup() else null;
    defer if (stored_current_function) |value| value.free(ctx.runtime);
    const current_function_value = stored_current_function orelse receiver;
    const resume_value = if (object.generatorPc() != 0 and args.len > 0) args[0] else core.JSValue.undefinedValue();
    object.generatorExecutingSlot().* = true;
    defer object.generatorExecutingSlot().* = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        current_function_value,
        object.generatorThis() orelse core.JSValue.undefinedValue(),
        object.generatorArgs(),
        object.functionCapturesSlot().*,
        output,
        generator_global,
        object.functionEvalLocalNamesSlot().*,
        object.functionEvalLocalRefsSlot().*,
        false,
        object,
        resume_value,
        null,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    ) catch |err| {
        object.generatorDoneSlot().* = true;
        if (object.class_id == core.class.ids.async_generator) {
            return try rejectedPromiseForRuntimeError(ctx, generator_global, err, promisePrototypeFromGlobal(ctx.runtime, generator_global));
        }
        return err;
    };
    if (object.class_id == core.class.ids.async_generator) {
        defer result.free(ctx.runtime);
        const promise = objectFromValue(result) orelse return error.TypeError;
        if (promise.class_id != core.class.ids.promise) return error.TypeError;
        if (promise.promiseIsRejected()) {
            object.generatorDoneSlot().* = true;
            return result.dup();
        }
        const done = !object.generatorJustYielded();
        if (promise.promiseResult() == null) {
            return try asyncGeneratorIteratorResultFromPromise(ctx, output, generator_global, result, done);
        }
        const value = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
        defer value.free(ctx.runtime);
        if (objectFromValue(value)) |inner_promise| {
            if (inner_promise.class_id == core.class.ids.promise and inner_promise.promiseIsRejected()) {
                object.generatorDoneSlot().* = true;
                if (ctx.hasException()) ctx.clearException();
                return value.dup();
            }
        }
        const iterator_result = try createIteratorResult(ctx.runtime, generator_global, value, done);
        defer iterator_result.free(ctx.runtime);
        return try builtins.promise.fulfilledWithPrototype(ctx.runtime, iterator_result, promisePrototypeFromGlobal(ctx.runtime, generator_global));
    }
    defer result.free(ctx.runtime);
    if (object.generatorJustYielded() and
        (object.generatorYieldStarIterator() != null or generatorYieldStarSuspended(ctx.runtime, object)))
    {
        return result.dup();
    }
    return try createIteratorResult(ctx.runtime, generator_global, result, !object.generatorJustYielded());
}

pub fn generatorYieldStarSuspended(rt: *core.JSRuntime, object: *core.Object) bool {
    _ = rt;
    return object.generatorYieldStarSuspended();
}

pub fn setGeneratorYieldStarSuspended(rt: *core.JSRuntime, object: *core.Object, value: bool) !void {
    _ = rt;
    object.generatorYieldStarSuspendedSlot().* = value;
}

pub fn generatorResumeCompletionType(rt: *core.JSRuntime, object: *core.Object) i32 {
    _ = rt;
    return object.generatorResumeCompletionType();
}

pub fn setGeneratorResumeCompletionType(rt: *core.JSRuntime, object: *core.Object, value: i32) !void {
    _ = rt;
    object.generatorResumeCompletionTypeSlot().* = value;
}

pub fn resumeGeneratorYieldStarCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    resume_value: core.JSValue,
    completion_type: i32,
) !core.JSValue {
    const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
    try setGeneratorResumeCompletionType(ctx.runtime, object, completion_type);
    object.generatorExecutingSlot().* = true;
    defer object.generatorExecutingSlot().* = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        receiver,
        object.generatorThis() orelse core.JSValue.undefinedValue(),
        object.generatorArgs(),
        object.functionCapturesSlot().*,
        output,
        global,
        object.functionEvalLocalNamesSlot().*,
        object.functionEvalLocalRefsSlot().*,
        false,
        object,
        resume_value,
        null,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    ) catch |err| {
        object.generatorDoneSlot().* = true;
        if (object.class_id == core.class.ids.async_generator) {
            return try rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
        }
        return err;
    };
    defer result.free(ctx.runtime);
    if (object.class_id == core.class.ids.async_generator) {
        const promise = objectFromValue(result) orelse return error.TypeError;
        if (promise.class_id != core.class.ids.promise) return error.TypeError;
        if (promise.promiseIsRejected()) {
            object.generatorDoneSlot().* = true;
            return result.dup();
        }
        const done = !object.generatorJustYielded();
        if (promise.promiseResult() == null) {
            if (done) object.generatorDoneSlot().* = true;
            return try asyncGeneratorIteratorResultFromPromise(ctx, output, global, result, done);
        }
        const value = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
        defer value.free(ctx.runtime);
        if (done) object.generatorDoneSlot().* = true;
        return try asyncGeneratorFulfilledIteratorResult(ctx, global, value, done);
    }
    const done = !object.generatorJustYielded();
    if (done) object.generatorDoneSlot().* = true;
    if (object.generatorJustYielded() and generatorYieldStarSuspended(ctx.runtime, object)) return result.dup();
    return try createIteratorResult(ctx.runtime, global, result, done);
}

pub fn qjsGeneratorReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    if (!receiver.isObject()) return null;
    const object = property_ops.expectObject(receiver) catch return null;
    if (object.class_id != core.class.ids.generator and object.class_id != core.class.ids.async_generator) return null;
    if (object.generatorExecuting()) return error.TypeError;
    const generator_global = objectRealmGlobal(object) orelse global;
    try closeGeneratorDestructuringIterators(ctx, output, generator_global, object);
    var return_value = if (args.len > 0) args[0].dup() else core.JSValue.undefinedValue();
    defer return_value.free(ctx.runtime);
    if (generatorYieldStarSuspended(ctx.runtime, object)) {
        return try resumeGeneratorYieldStarCompletion(ctx, output, generator_global, receiver, object, return_value, 1);
    }
    if (object.generatorYieldStarIterator() != null) {
        const step = qjsGeneratorYieldStarReturnStep(ctx, output, generator_global, object, return_value) catch |err| {
            if (try resumeGeneratorCatchForRuntimeError(ctx, output, generator_global, receiver, object, err)) |handled| return handled;
            return err;
        };
        switch (step) {
            .yield_result => |result| {
                if (object.class_id == core.class.ids.async_generator) {
                    defer result.free(ctx.runtime);
                    const promise = try builtins.promise.fulfilledWithPrototype(ctx.runtime, result, promisePrototypeFromGlobal(ctx.runtime, generator_global));
                    return promise;
                }
                return result;
            },
            .complete => |value| {
                return_value.free(ctx.runtime);
                return_value = value;
            },
        }
    }
    if (object.generatorPc() != 0) {
        const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (findGeneratorReturnFinallyTarget(fb, @intCast(object.generatorPc()))) |finally_range| {
            object.generatorPcSlot().* = finally_range.start;
            object.generatorJustYieldedSlot().* = false;
            const result = callFunctionBytecodeModeState(
                ctx,
                function_value,
                receiver,
                object.generatorThis() orelse core.JSValue.undefinedValue(),
                object.generatorArgs(),
                object.functionCapturesSlot().*,
                output,
                generator_global,
                object.functionEvalLocalNamesSlot().*,
                object.functionEvalLocalRefsSlot().*,
                false,
                object,
                core.JSValue.undefinedValue(),
                finally_range.stop,
                core.JSValue.undefinedValue(),
                core.JSValue.undefinedValue(),
            ) catch |err| {
                object.generatorDoneSlot().* = true;
                return err;
            };
            defer result.free(ctx.runtime);
            const done = !object.generatorJustYielded();
            if (done) object.generatorDoneSlot().* = true;
            const iterator_value = if (done and result.isUndefined()) return_value else result;
            if (object.class_id == core.class.ids.async_generator) {
                const promise = try asyncGeneratorFulfilledIteratorResult(ctx, generator_global, iterator_value, done);
                return promise;
            }
            return try createIteratorResult(ctx.runtime, generator_global, iterator_value, done);
        }
    }
    object.generatorDoneSlot().* = true;
    if (object.class_id == core.class.ids.async_generator) {
        const promise = try asyncGeneratorFulfilledIteratorResult(ctx, generator_global, return_value, true);
        return promise;
    }
    return try createIteratorResult(ctx.runtime, generator_global, return_value, true);
}

pub fn resumeGeneratorCatchForRuntimeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    err: anytype,
) !?core.JSValue {
    if (object.class_id == core.class.ids.async_generator) return null;
    if (object.generatorPc() == 0 or !object.generatorStarted()) return null;
    const function_value = object.functionBytecodeSlot().* orelse return null;
    const fb = functionBytecodeFromValue(function_value) orelse return null;
    const catch_target = findEnclosingCatchTarget(fb, @intCast(object.generatorPc())) orelse return null;
    const thrown = try exception_ops.runtimeErrorValueForGeneratorCatch(ctx, global, err);
    defer thrown.free(ctx.runtime);
    object.generatorPcSlot().* = catch_target;
    object.generatorJustYieldedSlot().* = false;
    const result = callFunctionBytecodeModeState(
        ctx,
        function_value,
        receiver,
        object.generatorThis() orelse core.JSValue.undefinedValue(),
        object.generatorArgs(),
        object.functionCapturesSlot().*,
        output,
        global,
        object.functionEvalLocalNamesSlot().*,
        object.functionEvalLocalRefsSlot().*,
        false,
        object,
        thrown,
        null,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    ) catch |resume_err| {
        object.generatorDoneSlot().* = true;
        return resume_err;
    };
    defer result.free(ctx.runtime);
    const done = !object.generatorJustYielded();
    if (done) object.generatorDoneSlot().* = true;
    const result_value = generatorCatchResumeResultValue(result);
    return try createIteratorResult(ctx.runtime, global, result_value, done);
}

pub const GeneratorYieldStarReturnStep = union(enum) {
    yield_result: core.JSValue,
    complete: core.JSValue,
};

pub const GeneratorYieldStarThrowStep = union(enum) {
    yield_result: core.JSValue,
    complete: core.JSValue,
};

pub fn qjsGeneratorYieldStarReturnStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    generator: *core.Object,
    return_arg: core.JSValue,
) !GeneratorYieldStarReturnStep {
    const iterator_value = (generator.generatorYieldStarIterator() orelse return error.TypeError).dup();
    defer iterator_value.free(ctx.runtime);
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, iterator_value, return_key, null, null);
    defer return_method.free(ctx.runtime);

    if (return_method.isUndefined() or return_method.isNull()) {
        generator.clearOptionalValueSlot(ctx.runtime, generator.generatorYieldStarIteratorSlot());
        return .{ .complete = return_arg.dup() };
    }
    if (!isCallableValue(return_method)) return error.TypeError;

    const result_value = try callValueOrBytecode(ctx, output, global, iterator_value, return_method, &.{return_arg}, null, null);
    errdefer result_value.free(ctx.runtime);
    const result = property_ops.expectObject(result_value) catch return error.TypeError;

    const done_key = core.atom.predefinedId("done", .string).?;
    const done_value = try getValueProperty(ctx, output, global, result.value(), done_key, null, null);
    defer done_value.free(ctx.runtime);
    const is_done = value_ops.isTruthy(done_value);

    if (!is_done) {
        generator.generatorJustYieldedSlot().* = true;
        return .{ .yield_result = result_value };
    }

    const value_key = core.atom.predefinedId("value", .string).?;
    const value = try getValueProperty(ctx, output, global, result.value(), value_key, null, null);
    errdefer value.free(ctx.runtime);
    result_value.free(ctx.runtime);
    generator.clearOptionalValueSlot(ctx.runtime, generator.generatorYieldStarIteratorSlot());
    return .{ .complete = value };
}

pub fn qjsGeneratorYieldStarThrowStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    generator: *core.Object,
    thrown: core.JSValue,
) !GeneratorYieldStarThrowStep {
    const iterator_value = (generator.generatorYieldStarIterator() orelse return error.TypeError).dup();
    defer iterator_value.free(ctx.runtime);
    const throw_key = try ctx.runtime.internAtom("throw");
    defer ctx.runtime.atoms.free(throw_key);
    const throw_method = try getValueProperty(ctx, output, global, iterator_value, throw_key, null, null);
    defer throw_method.free(ctx.runtime);

    if (throw_method.isUndefined() or throw_method.isNull()) {
        try qjsGeneratorYieldStarCloseForMissingThrow(ctx, output, global, iterator_value);
        generator.clearOptionalValueSlot(ctx.runtime, generator.generatorYieldStarIteratorSlot());
        return error.TypeError;
    }
    if (!isCallableValue(throw_method)) return error.TypeError;

    const result_value = try callValueOrBytecode(ctx, output, global, iterator_value, throw_method, &.{thrown}, null, null);
    errdefer result_value.free(ctx.runtime);
    const result = property_ops.expectObject(result_value) catch return error.TypeError;

    const done_key = core.atom.predefinedId("done", .string).?;
    const done_value = try getValueProperty(ctx, output, global, result.value(), done_key, null, null);
    defer done_value.free(ctx.runtime);
    const is_done = value_ops.isTruthy(done_value);

    if (!is_done) {
        generator.generatorJustYieldedSlot().* = true;
        return .{ .yield_result = result_value };
    }

    const value_key = core.atom.predefinedId("value", .string).?;
    const value = try getValueProperty(ctx, output, global, result.value(), value_key, null, null);
    errdefer value.free(ctx.runtime);
    result_value.free(ctx.runtime);
    generator.clearOptionalValueSlot(ctx.runtime, generator.generatorYieldStarIteratorSlot());
    return .{ .complete = value };
}

pub fn qjsGeneratorYieldStarCloseForMissingThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, iterator_value, return_key, null, null);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) return;
    if (!isCallableValue(return_method)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, iterator_value, return_method, &.{}, null, null);
    defer result.free(ctx.runtime);
    _ = property_ops.expectObject(result) catch return error.TypeError;
}

pub fn qjsGeneratorYieldStarReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    generator: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const return_arg = if (args.len > 0) args[0] else core.JSValue.undefinedValue();
    const step = try qjsGeneratorYieldStarReturnStep(ctx, output, global, generator, return_arg);
    switch (step) {
        .yield_result => |result| return result,
        .complete => |value| {
            defer value.free(ctx.runtime);
            generator.generatorDoneSlot().* = true;
            return try createIteratorResult(ctx.runtime, global, value, true);
        },
    }
}

pub fn qjsGeneratorThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !?core.JSValue {
    const object = property_ops.expectObject(receiver) catch return null;
    if (object.class_id != core.class.ids.generator and object.class_id != core.class.ids.async_generator) return null;
    if (object.generatorExecuting()) return error.TypeError;
    const generator_global = objectRealmGlobal(object) orelse global;
    const thrown = if (args.len > 0) args[0] else core.JSValue.undefinedValue();

    if (generatorYieldStarSuspended(ctx.runtime, object)) {
        return try resumeGeneratorYieldStarCompletion(ctx, output, generator_global, receiver, object, thrown, 2);
    }

    if (object.class_id == core.class.ids.async_generator) {
        object.generatorDoneSlot().* = true;
        return try builtins.promise.rejectedWithPrototype(ctx.runtime, thrown, promisePrototypeFromGlobal(ctx.runtime, generator_global));
    }

    if (object.generatorYieldStarIterator() != null) {
        const step = qjsGeneratorYieldStarThrowStep(ctx, output, generator_global, object, thrown) catch |err| {
            if (try resumeGeneratorCatchForRuntimeError(ctx, output, generator_global, receiver, object, err)) |handled| return handled;
            object.generatorDoneSlot().* = true;
            return err;
        };
        switch (step) {
            .yield_result => |result| return result,
            .complete => |value| {
                defer value.free(ctx.runtime);
                const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
                const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
                object.generatorPcSlot().* = generatorPcAfterYieldStar(fb, object.generatorPc()) orelse return error.InvalidBytecode;
                object.generatorJustYieldedSlot().* = false;
                const result = callFunctionBytecodeModeState(
                    ctx,
                    function_value,
                    receiver,
                    object.generatorThis() orelse core.JSValue.undefinedValue(),
                    object.generatorArgs(),
                    object.functionCapturesSlot().*,
                    output,
                    generator_global,
                    object.functionEvalLocalNamesSlot().*,
                    object.functionEvalLocalRefsSlot().*,
                    false,
                    object,
                    value,
                    null,
                    core.JSValue.undefinedValue(),
                    core.JSValue.undefinedValue(),
                ) catch |err| {
                    object.generatorDoneSlot().* = true;
                    return err;
                };
                defer result.free(ctx.runtime);
                const done = !object.generatorJustYielded();
                if (done) object.generatorDoneSlot().* = true;
                return try createIteratorResult(ctx.runtime, generator_global, result, done);
            },
        }
    }

    if (object.generatorPc() != 0 and object.generatorStarted()) {
        const function_value = object.functionBytecodeSlot().* orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (findEnclosingCatchTarget(fb, @intCast(object.generatorPc()))) |catch_target| {
            object.generatorPcSlot().* = catch_target;
            object.generatorJustYieldedSlot().* = false;
            const result = callFunctionBytecodeModeState(
                ctx,
                function_value,
                receiver,
                object.generatorThis() orelse core.JSValue.undefinedValue(),
                object.generatorArgs(),
                object.functionCapturesSlot().*,
                output,
                generator_global,
                object.functionEvalLocalNamesSlot().*,
                object.functionEvalLocalRefsSlot().*,
                false,
                object,
                thrown,
                null,
                core.JSValue.undefinedValue(),
                core.JSValue.undefinedValue(),
            ) catch |err| {
                object.generatorDoneSlot().* = true;
                return err;
            };
            defer result.free(ctx.runtime);
            const done = !object.generatorJustYielded();
            if (done) object.generatorDoneSlot().* = true;
            const result_value = generatorCatchResumeResultValue(result);
            return try createIteratorResult(ctx.runtime, generator_global, result_value, done);
        }
    }

    object.generatorDoneSlot().* = true;
    _ = ctx.throwValue(thrown.dup());
    return error.JSException;
}

pub fn generatorCatchResumeResultValue(result: core.JSValue) core.JSValue {
    return if (result.isCatchOffset()) core.JSValue.undefinedValue() else result;
}

pub fn generatorPcAfterYieldStar(fb: *const bytecode.FunctionBytecode, pc: usize) ?usize {
    if (pc >= fb.byte_code.len) return null;
    const op_id = fb.byte_code[pc];
    if (op_id != op.yield_star and op_id != op.async_yield_star) return null;
    const size = bytecode.opcode.sizeOf(op_id);
    if (size == 0 or pc + size > fb.byte_code.len) return null;
    return pc + size;
}

pub const GeneratorReturnFinallyRange = struct {
    start: usize,
    stop: usize,
};

pub fn findGeneratorReturnFinallyTarget(fb: *const bytecode.FunctionBytecode, start_pc: u32) ?GeneratorReturnFinallyRange {
    var pc: usize = 0;
    var found: ?GeneratorReturnFinallyRange = null;
    while (pc < start_pc and pc < fb.byte_code.len) {
        const op_id = fb.byte_code[pc];
        if (op_id == op.@"catch") {
            if (pc + 5 > fb.byte_code.len) return found;
            const operand_pc = pc + 1;
            const diff = readInt(i32, fb.byte_code[operand_pc..][0..4]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target > start_pc and target <= fb.byte_code.len) {
                if (findGeneratorReturnFinallyTargetFromCatch(fb, @intCast(target))) |candidate| {
                    if (found == null or candidate.stop > found.?.stop) {
                        found = candidate;
                    }
                }
            }
        }
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0) return found;
        pc += size;
    }
    return found;
}

pub fn findGeneratorReturnFinallyTargetFromCatch(fb: *const bytecode.FunctionBytecode, catch_target: usize) ?GeneratorReturnFinallyRange {
    const rethrow_pc = findThrowFrom(fb, catch_target) orelse return null;
    if (rethrow_pc <= catch_target) return null;
    if (findForwardGotoTargetInRange(fb, catch_target, rethrow_pc)) |normal_finally_target| {
        if (normal_finally_target > rethrow_pc) {
            return .{ .start = normal_finally_target, .stop = fb.byte_code.len };
        }
    }
    return .{ .start = catch_target, .stop = rethrow_pc };
}

pub fn findForwardGotoTargetInRange(fb: *const bytecode.FunctionBytecode, start_pc: usize, end_pc: usize) ?usize {
    var pc = start_pc;
    var found: ?usize = null;
    while (pc < end_pc and pc < fb.byte_code.len) {
        const op_id = fb.byte_code[pc];
        if (forwardGotoTarget(fb, pc)) |target| {
            if (target > pc and target <= fb.byte_code.len) found = @intCast(target);
        }
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0) return found;
        pc += size;
    }
    return found;
}

pub fn findEnclosingCatchTarget(fb: *const bytecode.FunctionBytecode, start_pc: u32) ?usize {
    var pc: usize = 0;
    var found: ?usize = null;
    while (pc < start_pc and pc < fb.byte_code.len) {
        const op_id = fb.byte_code[pc];
        if (op_id == op.@"catch") {
            if (pc + 5 > fb.byte_code.len) return found;
            const operand_pc = pc + 1;
            const diff = readInt(i32, fb.byte_code[operand_pc..][0..4]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target > start_pc and target <= fb.byte_code.len) found = @intCast(target);
        }
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0) return null;
        pc += size;
    }
    return found;
}

pub fn findThrowFrom(fb: *const bytecode.FunctionBytecode, start_pc: usize) ?usize {
    var pc = start_pc;
    while (pc < fb.byte_code.len) {
        const op_id = fb.byte_code[pc];
        if (op_id == op.throw) return pc;
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0) return null;
        pc += size;
    }
    return null;
}

pub fn forwardGotoTarget(fb: *const bytecode.FunctionBytecode, pc: usize) ?u32 {
    const op_id = fb.byte_code[pc];
    return switch (op_id) {
        op.goto8 => blk: {
            if (pc + 1 >= fb.byte_code.len) break :blk null;
            const operand_pc = pc + 1;
            const diff: i8 = @bitCast(fb.byte_code[operand_pc]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            break :blk if (target > @as(i64, @intCast(pc)) and target <= @as(i64, @intCast(fb.byte_code.len))) @as(u32, @intCast(target)) else null;
        },
        op.goto16 => blk: {
            if (pc + 3 > fb.byte_code.len) break :blk null;
            const operand_pc = pc + 1;
            const diff = readInt(i16, fb.byte_code[operand_pc..][0..2]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            break :blk if (target > @as(i64, @intCast(pc)) and target <= @as(i64, @intCast(fb.byte_code.len))) @as(u32, @intCast(target)) else null;
        },
        op.goto => blk: {
            if (pc + 5 > fb.byte_code.len) break :blk null;
            const operand_pc = pc + 1;
            const diff = readInt(i32, fb.byte_code[operand_pc..][0..4]);
            const target = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            break :blk if (target > @as(i64, @intCast(pc)) and target <= @as(i64, @intCast(fb.byte_code.len))) @as(u32, @intCast(target)) else null;
        },
        else => null,
    };
}

pub fn closeGeneratorDestructuringIterators(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    generator: *core.Object,
) !void {
    try closeDestructuringIteratorsInValues(ctx, output, global, generator.generatorStack());
    try closeDestructuringIteratorsInValues(ctx, output, global, generator.generatorFrameLocals());
    try closeDestructuringIteratorsInValues(ctx, output, global, generator.generatorFrameArgs());
    try closeDestructuringIteratorsInValues(ctx, output, global, generator.generatorFrameVarRefs());
}

pub fn closeDestructuringIteratorsInValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    values: []const core.JSValue,
) !void {
    for (values) |value| {
        const object = property_ops.expectObject(value) catch continue;
        if (!isDestructuringIteratorState(object)) continue;
        if (destructuringIteratorStateClosing(object)) continue;
        const close_arg = value.dup();
        defer close_arg.free(ctx.runtime);
        const close_result = try qjsDestructuringClose(ctx, output, global, &.{close_arg});
        close_result.free(ctx.runtime);
    }
}

pub fn closeDestructuringIteratorsInValuesForAbruptCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    values: []const core.JSValue,
) void {
    for (values) |value| {
        const object = property_ops.expectObject(value) catch continue;
        if (!isDestructuringIteratorState(object)) continue;
        if (destructuringIteratorStateClosing(object)) continue;
        const close_arg = value.dup();
        defer close_arg.free(ctx.runtime);
        const pending_exception = if (ctx.hasException()) ctx.takeException() else null;
        defer if (pending_exception) |pending| pending.free(ctx.runtime);
        const close_result = qjsDestructuringClose(ctx, output, global, &.{close_arg}) catch {
            if (ctx.hasException()) ctx.clearException();
            if (pending_exception) |pending| _ = ctx.throwValue(pending.dup());
            clearDestructuringIteratorState(ctx.runtime, object) catch {};
            continue;
        };
        close_result.free(ctx.runtime);
        if (ctx.hasException()) ctx.clearException();
        if (pending_exception) |pending| _ = ctx.throwValue(pending.dup());
    }
}

pub fn closeFrameDestructuringIteratorsForAbruptCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *const stack_mod.Stack,
    frame: *const frame_mod.Frame,
) void {
    closeDestructuringIteratorsInValuesForAbruptCompletion(ctx, output, global, stack.values);
    closeDestructuringIteratorsInValuesForAbruptCompletion(ctx, output, global, frame.locals);
    closeDestructuringIteratorsInValuesForAbruptCompletion(ctx, output, global, frame.args);
    closeDestructuringIteratorsInValuesForAbruptCompletion(ctx, output, global, frame.var_refs);
}

pub fn qjsIteratorCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    switch (id) {
        @intFromEnum(builtins.iterator.AccessorMethod.constructor_getter),
        @intFromEnum(builtins.iterator.AccessorMethod.constructor_setter),
        @intFromEnum(builtins.iterator.AccessorMethod.to_string_tag_getter),
        @intFromEnum(builtins.iterator.AccessorMethod.to_string_tag_setter),
        => return @as(?core.JSValue, try qjsIteratorPrototypeAccessor(ctx, global, receiver, args, id)),
        else => {},
    }
    if (try qjsIteratorStaticCall(ctx, output, global, args, id, caller_function, caller_frame)) |value| return value;
    return qjsIteratorPrototypeMethodCall(ctx, output, global, receiver, args, id, caller_function, caller_frame);
}

pub fn qjsIteratorStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    method_id: u32,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return switch (method_id) {
        @intFromEnum(builtins.iterator.StaticMethod.from) => try qjsIteratorFromCall(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(builtins.iterator.StaticMethod.concat) => try qjsIteratorConcatCall(ctx, output, global, args),
        @intFromEnum(builtins.iterator.StaticMethod.zip) => try qjsIteratorZipCall(ctx, output, global, args, false, caller_function, caller_frame),
        @intFromEnum(builtins.iterator.StaticMethod.zip_keyed) => try qjsIteratorZipCall(ctx, output, global, args, true, caller_function, caller_frame),
        else => null,
    };
}

pub fn qjsIteratorFromCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return iter_vm.qjsIteratorFromCall(
        ctx,
        output,
        global,
        args,
        caller_function,
        caller_frame,
        iteratorFromSourceForIteratorFrom,
        wrapIteratorFromIterator,
    );
}

pub const IteratorZipMode = iter_vm.IteratorZipMode;
pub const IteratorZipRecord = iter_vm.IteratorZipRecord;
pub const IteratorZipCompletion = iter_vm.IteratorZipCompletion;

pub fn qjsIteratorZipCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    keyed: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return iter_vm.qjsIteratorZipCall(
        ctx,
        output,
        global,
        args,
        keyed,
        caller_function,
        caller_frame,
        getValueProperty,
        iteratorForValue,
        callValueOrBytecode,
        valueTruthy,
        stringValueUnitsEqualBytes,
        objectRestOwnKeys,
        proxyAwareOwnPropertyDescriptor,
        proxyTrapKeyValue,
        qjsIteratorClose,
        isCallableValue,
    );
}

pub fn qjsIteratorZipModeFromOptions(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorZipMode {
    return iter_vm.qjsIteratorZipModeFromOptions(ctx, output, global, options, caller_function, caller_frame, getValueProperty, stringValueUnitsEqualBytes);
}

pub fn qjsIteratorZipCollectIndexed(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterables_iterator: core.JSValue,
    iterables_next: core.JSValue,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    padding: core.JSValue,
    mode: IteratorZipMode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    return iter_vm.qjsIteratorZipCollectIndexed(
        ctx,
        output,
        global,
        iterables_iterator,
        iterables_next,
        iters,
        nexts,
        pads,
        padding,
        mode,
        caller_function,
        caller_frame,
        getValueProperty,
        iteratorForValue,
        callValueOrBytecode,
        valueTruthy,
        qjsIteratorClose,
        isCallableValue,
    );
}

pub fn qjsIteratorZipCollectKeyed(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterables: *core.Object,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    keys: *core.Object,
    padding: core.JSValue,
    mode: IteratorZipMode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    return iter_vm.qjsIteratorZipCollectKeyed(
        ctx,
        output,
        global,
        iterables,
        iters,
        nexts,
        pads,
        keys,
        padding,
        mode,
        caller_function,
        caller_frame,
        getValueProperty,
        callValueOrBytecode,
        qjsIteratorClose,
        objectRestOwnKeys,
        proxyAwareOwnPropertyDescriptor,
        proxyTrapKeyValue,
        isCallableValue,
    );
}

pub fn qjsIteratorZipNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return iter_vm.qjsIteratorZipNextMethod(
        ctx,
        output,
        global,
        iterator_value,
        caller_function,
        caller_frame,
        getValueProperty,
        isCallableValue,
    );
}

pub fn qjsIteratorZipCreateHelper(
    rt: *core.JSRuntime,
    global: *core.Object,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    keys: ?*core.Object,
    count: usize,
    mode: IteratorZipMode,
    keyed: bool,
) !core.JSValue {
    return iter_vm.qjsIteratorZipCreateHelper(rt, global, iters, nexts, pads, keys, count, mode, keyed);
}

pub fn qjsIteratorZipStoreIndex(rt: *core.JSRuntime, object: *core.Object, index: usize, value: core.JSValue) !void {
    try iter_vm.qjsIteratorZipStoreIndex(rt, object, index, value);
}

pub fn qjsIteratorZipGetIndex(object: *core.Object, index: usize) core.JSValue {
    return iter_vm.qjsIteratorZipGetIndex(object, index);
}

pub fn qjsIteratorZipSetIndex(rt: *core.JSRuntime, object: *core.Object, index: usize, value: core.JSValue) !void {
    try iter_vm.qjsIteratorZipSetIndex(rt, object, index, value);
}

pub fn qjsIteratorZipCloseWithCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    completion: *IteratorZipCompletion,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) void {
    iter_vm.qjsIteratorZipCloseWithCompletion(ctx, output, global, completion, iterator_value, caller_function, caller_frame, qjsIteratorClose);
}

pub fn qjsIteratorZipCloseAllWithCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    completion: *IteratorZipCompletion,
    iters: *core.Object,
    count: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    try iter_vm.qjsIteratorZipCloseAllWithCompletion(ctx, output, global, completion, iters, count, caller_function, caller_frame, qjsIteratorClose);
}

pub fn qjsIteratorZipClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    try iter_vm.qjsIteratorZipClose(ctx, output, global, iterator_value, caller_function, caller_frame, qjsIteratorClose);
}

pub fn iteratorCloseWithCompletionAndPropagate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    err: anytype,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    defer completion.deinit(ctx.runtime);
    qjsIteratorZipCloseWithCompletion(ctx, output, global, &completion, iterator_value, caller_function, caller_frame);
    completion.restore(ctx);
    return completion.err orelse err;
}

pub fn qjsIteratorZipCloseAllAndPropagate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iters: *core.Object,
    count: usize,
    err: anytype,
    extra_iterator: ?core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError {
    return iter_vm.qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, extra_iterator, caller_function, caller_frame, qjsIteratorClose);
}

pub fn iteratorFromSourceForIteratorFrom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !iter_vm.IteratorFromResult {
    if (source.isString()) {
        const iterator_method = try getIteratorMethod(ctx, output, global, source);
        defer iterator_method.free(ctx.runtime);
        const iterator = try callValueOrBytecode(ctx, output, global, source, iterator_method, &.{}, caller_function, caller_frame);
        errdefer iterator.free(ctx.runtime);
        return .{ .iterator = iterator };
    }

    const source_object = objectFromValue(source) orelse return error.TypeError;
    if (iteratorIsOnIteratorPrototypeChain(ctx.runtime, global, source)) {
        return .{ .iterator = source.dup() };
    }

    const iterator_method = try getIteratorMethod(ctx, output, global, source);
    defer iterator_method.free(ctx.runtime);
    if (!iterator_method.isUndefined() and !iterator_method.isNull()) {
        if (!isCallableValue(iterator_method)) return error.TypeError;
        const iterator = try callValueOrBytecode(ctx, output, global, source, iterator_method, &.{}, caller_function, caller_frame);
        errdefer iterator.free(ctx.runtime);
        _ = objectFromValue(iterator) orelse return error.TypeError;
        return .{ .iterator = iterator };
    }

    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, source, next_key, caller_function, caller_frame);
    errdefer next_method.free(ctx.runtime);
    return .{ .iterator = source_object.value().dup(), .next_method = next_method, .wrap = true };
}

pub fn isDirectIteratorClass(class_id: core.class.ClassId) bool {
    return class_id == core.class.ids.array_iterator or
        class_id == core.class.ids.string_iterator or
        class_id == core.class.ids.map_iterator or
        class_id == core.class.ids.set_iterator or
        class_id == core.class.ids.regexp_string_iterator or
        class_id == core.class.ids.generator or
        class_id == core.class.ids.iterator_wrap;
}

pub fn wrapIteratorFromIterator(ctx: *core.JSContext, global: *core.Object, iterator: core.JSValue, next_method: ?core.JSValue) !core.JSValue {
    var rooted_iterator = iterator;
    var rooted_next_method = next_method orelse core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_iterator },
        .{ .value = &rooted_next_method },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const iterator_object = objectFromValue(rooted_iterator) orelse return error.TypeError;
    const prototype = try wrapForValidIteratorPrototype(ctx.runtime, global);
    const wrapper = try core.Object.create(ctx.runtime, core.class.ids.iterator_wrap, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &wrapper.header);
    try wrapper.setOptionalValueSlot(ctx.runtime, wrapper.iteratorTargetSlot(), rooted_iterator.dup());
    if (next_method != null) {
        try wrapper.setOptionalValueSlot(ctx.runtime, wrapper.iteratorNextSlot(), rooted_next_method.dup());
        return wrapper.value();
    }
    if (iterator_object.cachedIteratorNext()) |cached_next_method| {
        try wrapper.setOptionalValueSlot(ctx.runtime, wrapper.iteratorNextSlot(), cached_next_method.dup());
        iterator_object.clearCachedIteratorNext(ctx.runtime);
    }
    return wrapper.value();
}

test "wrapIteratorFromIterator roots direct function bytecode next method while creating wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    defer iterator.value().free(rt);

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer prototype.value().free(rt);
    try storeRealmValue(rt, global, .wrap_for_valid_iterator_prototype, prototype.value());

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-wrap-iterator-next-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var next_method = core.JSValue.functionBytecode(&fb.header);
    var next_method_alive = true;
    defer if (next_method_alive) next_method.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const wrapper_value = try wrapIteratorFromIterator(ctx, global, iterator.value(), next_method);
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.iteratorNext() orelse return error.TypeError;
    try std.testing.expect(stored.same(next_method));

    wrapper_value.free(rt);
    wrapper_alive = false;
    next_method.free(rt);
    next_method_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsIteratorWrapNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (function_object.functionIteratorWrapMethod() != 1) return null;
    const wrapper = objectFromValue(receiver) orelse return error.TypeError;
    if (wrapper.class_id != core.class.ids.iterator_wrap) return error.TypeError;
    const iterator = (wrapper.iteratorTargetSlot().*) orelse return error.TypeError;
    const next_method = if (wrapper.iteratorNext()) |stored| stored.dup() else blk: {
        const next_key = try ctx.runtime.internAtom("next");
        defer ctx.runtime.atoms.free(next_key);
        const method = try getValueProperty(ctx, output, global, iterator, next_key, caller_function, caller_frame);
        errdefer method.free(ctx.runtime);
        if (!isCallableValue(method)) return error.TypeError;
        break :blk method;
    };
    defer next_method.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, iterator, next_method, &.{}, caller_function, caller_frame);
    errdefer result.free(ctx.runtime);
    _ = objectFromValue(result) orelse return error.TypeError;
    return result;
}

pub fn qjsIteratorWrapReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (function_object.functionIteratorWrapMethod() != 2) return null;
    const wrapper = objectFromValue(receiver) orelse return error.TypeError;
    if (wrapper.class_id != core.class.ids.iterator_wrap) return error.TypeError;
    const iterator = (wrapper.iteratorTargetSlot().*) orelse return error.TypeError;
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, iterator, return_key, caller_function, caller_frame);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) {
        return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    }
    if (!isCallableValue(return_method)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, iterator, return_method, &.{}, caller_function, caller_frame);
    errdefer result.free(ctx.runtime);
    _ = objectFromValue(result) orelse return error.TypeError;
    return result;
}

pub fn qjsIteratorHelperNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return iter_vm.qjsIteratorHelperNext(
        ctx,
        output,
        global,
        receiver,
        function_object,
        caller_function,
        caller_frame,
        createIteratorResult,
        getValueProperty,
        callValueOrBytecode,
        valueTruthy,
        qjsIteratorClose,
        arrayPrototypeFromGlobal,
        isCallableValue,
    );
}

pub fn qjsIteratorHelperReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return iter_vm.qjsIteratorHelperReturn(
        ctx,
        output,
        global,
        receiver,
        function_object,
        caller_function,
        caller_frame,
        createIteratorResult,
        getValueProperty,
        callValueOrBytecode,
        valueTruthy,
        qjsIteratorClose,
        arrayPrototypeFromGlobal,
        isCallableValue,
    );
}

pub fn pollGCSafePoint(ctx: *core.JSContext) !void {
    _ = ctx.runtime.gcSafepoint(ctx.runtime.active_value_roots) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PayloadMarkFailed => return error.OutOfMemory,
    };
}

pub fn enqueueOsTimer(ctx: *core.JSContext, id: i64, callback: core.JSValue, delay_ms: u64, repeats: bool) HostError!void {
    const host_event_loop = ctx.hostEventLoop() orelse return error.TypeError;
    host_event_loop.enqueueTimer(ctx, id, callback, delay_ms, repeats) catch |err| return @errorCast(err);
}

pub fn clearOsTimer(ctx: *core.JSContext, id: i64) void {
    if (ctx.hostEventLoop()) |host_event_loop| {
        host_event_loop.clearTimer(ctx, id);
    }
}

pub fn runNextOsTimer(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) HostError!bool {
    if (ctx.hostEventLoop()) |host_event_loop| {
        return host_event_loop.runNextTimer(ctx, output, global) catch |err| return @errorCast(err);
    }
    return false;
}

pub fn runNextOsRwHandler(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) HostError!bool {
    if (ctx.hostEventLoop()) |host_event_loop| {
        return host_event_loop.runNextRwHandler(ctx, output, global) catch |err| return @errorCast(err);
    }
    return false;
}

pub fn enqueuePendingMicrotask(ctx: *core.JSContext, callback: core.JSValue) !void {
    try enqueuePendingPromiseJob(ctx, callback);
}

pub fn createIteratorResult(rt: *core.JSRuntime, global: *core.Object, value: core.JSValue, done: bool) !core.JSValue {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try defineValueProperty(rt, object, "value", rooted_value);
    try defineValueProperty(rt, object, "done", core.JSValue.boolean(done));
    return object.value();
}

test "createIteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-result-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var result_value = core.JSValue.functionBytecode(&fb.header);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try createIteratorResult(rt, global, result_value, false);
    var iterator_result_alive = true;
    defer if (iterator_result_alive) iterator_result_value.free(rt);
    const iterator_result = objectFromValue(iterator_result_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    const stored = iterator_result.getProperty(value_atom);
    defer stored.free(rt);
    try std.testing.expect(stored.same(result_value));

    iterator_result_value.free(rt);
    iterator_result_alive = false;
    result_value.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn throwTypeErrorIntrinsicForGlobal(rt: *core.JSRuntime, global: *core.Object) !core.JSValue {
    if (global.cachedThrowTypeErrorIntrinsic()) |stored| return stored.dup();

    const thrower = try builtins.function.nativeFunction(rt, "", 0);
    errdefer thrower.free(rt);
    const thrower_object = try property_ops.expectObject(thrower);
    try thrower_object.setFunctionRealmGlobalPtr(rt, global);
    if (functionPrototypeFromGlobal(rt, global)) |function_prototype| {
        try thrower_object.setPrototype(rt, function_prototype);
    }

    try thrower_object.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(0), false, false, false));
    const empty_name = try value_ops.createStringValue(rt, "");
    defer empty_name.free(rt);
    try thrower_object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(empty_name, false, false, false));
    if (!thrower_object.addThrowTypeErrorIntrinsicFunction()) return error.TypeError;
    try thrower_object.freeze(rt);

    try installFunctionPrototypeThrowTypeErrorAccessors(rt, global, thrower);
    const cached_thrower = try global.cachedThrowTypeErrorIntrinsicSlot(rt);
    try global.setOptionalValueSlot(rt, cached_thrower, thrower.dup());
    return thrower;
}

pub fn qjsThrowTypeErrorIntrinsic(ctx: *core.JSContext, global: *core.Object, function_object: *core.Object) !core.JSValue {
    const error_global = objectRealmGlobal(function_object) orelse global;
    const error_value = try createNamedError(ctx.runtime, error_global, "TypeError", "invalid property access");
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

pub fn currentFrameFunctionIsStrict(frame: *frame_mod.Frame) bool {
    if (frame.function.flags.is_strict or frame.function.flags.runtime_strict) return true;
    const fb = if (functionBytecodeFromValue(frame.current_function)) |bytecode_value|
        bytecode_value
    else if (objectFromValue(frame.current_function)) |function_object|
        if (function_object.functionBytecodeSlot().*) |stored| functionBytecodeFromValue(stored) else null
    else
        null;
    if (fb) |function_bytecode| return function_bytecode.is_strict_mode or function_bytecode.runtime_strict_mode;
    return false;
}

pub fn functionBytecodeFromValue(value: core.JSValue) ?*const bytecode.FunctionBytecode {
    const header = value.objectHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

pub fn isFunctionLikeClass(class_id: core.class.ClassId) bool {
    return class_id == core.class.ids.c_function or
        class_id == core.class.ids.c_closure or
        class_id == core.class.ids.bytecode_function or
        class_id == core.class.ids.bound_function;
}

pub fn isConstructorLike(ctx: *core.JSContext, value: core.JSValue) bool {
    if (value.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(value) orelse return false;
        return !fb.is_arrow_function and fb.has_prototype and fb.func_kind != .generator and fb.func_kind != .async_generator;
    }
    if (functionObjectFromValue(value)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return false;
        const fb = functionBytecodeFromValue(function_value) orelse return false;
        return !fb.is_arrow_function and fb.has_prototype and fb.func_kind != .generator and fb.func_kind != .async_generator;
    }
    if (callableObjectFromValue(value)) |function_object| {
        if (function_object.class_id == core.class.ids.bound_function) {
            const target = function_object.boundTarget() orelse return false;
            return isConstructorLike(ctx, target);
        }
        if (function_object.is_html_dda) return false;
        if (builtins.date.isConstructorRecord(function_object)) return true;
        if (function_object.hostFunctionKindSlot().* == core.host_function.ids.external_host) {
            return function_object.hasOwnProperty(core.atom.ids.prototype);
        }
        if (function_object.class_id == core.class.ids.c_closure) return true;
        const name = call_mod.nativeFunctionNameForVm(ctx.runtime, function_object) catch return false;
        defer ctx.runtime.memory.allocator.free(name);
        return isBuiltinConstructorName(name);
    }
    return proxyTargetIsConstructor(ctx, value);
}

pub fn callBoundFunction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const target = object.boundTarget() orelse return error.TypeError;
    const bound_this = object.boundThis() orelse return error.TypeError;
    const combined = try boundFunctionArgs(ctx.runtime, object, args);
    defer freeArgs(ctx.runtime, combined);
    return callValueOrBytecode(ctx, output, global, bound_this, target, combined, caller_function, caller_frame);
}

pub fn boundFunctionArgs(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue) ![]core.JSValue {
    const bound_args = object.boundArgs();
    const bound_count = bound_args.len;
    const combined = try rt.memory.alloc(core.JSValue, bound_count + args.len);
    errdefer rt.memory.free(core.JSValue, combined);
    var filled: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < filled) : (index += 1) combined[index].free(rt);
    }
    for (bound_args, 0..) |arg, index| {
        combined[index] = arg.dup();
        filled += 1;
    }
    for (args, 0..) |arg, arg_index| {
        combined[bound_count + arg_index] = arg.dup();
        filled += 1;
    }
    return combined;
}

pub fn throwPrivateBrandTypeError(
    ctx: *core.JSContext,
    global: *core.Object,
    atom_id: core.Atom,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const error_global = if (caller_frame) |frame| blk: {
        const function_object = objectFromValue(frame.current_function) orelse break :blk global;
        break :blk objectRealmGlobal(function_object) orelse global;
    } else global;
    const atom_name = ctx.runtime.atoms.name(atom_id) orelse "";
    const message = try std.fmt.allocPrint(
        ctx.runtime.memory.allocator,
        "private class field '{s}' does not exist",
        .{atom_name},
    );
    defer ctx.runtime.memory.allocator.free(message);
    return throwTypeErrorMessage(ctx, error_global, message);
}

pub const SetFailureError = error{
    AccessorWithoutSetter,
    IncompatibleDescriptor,
    NotExtensible,
    ReadOnly,
    TypeError,
};

pub fn throwSetFailureTypeError(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, reason: SetFailureError) !core.JSValue {
    const static_message = switch (reason) {
        error.AccessorWithoutSetter => "no setter for property",
        error.NotExtensible => "object is not extensible",
        else => null,
    };
    if (static_message) |message| return throwTypeErrorMessage(ctx, global, message);

    if (ctx.runtime.atoms.name(atom_id)) |name| {
        const message = try std.fmt.allocPrint(ctx.runtime.memory.allocator, "'{s}' is read-only", .{name});
        defer ctx.runtime.memory.allocator.free(message);
        return throwTypeErrorMessage(ctx, global, message);
    }
    return throwTypeErrorMessage(ctx, global, "property is read-only");
}

pub fn setFailureShouldThrow(caller_function: ?*const bytecode.Bytecode) bool {
    if (caller_function) |function| return functionRuntimeStrict(function);
    return false;
}

pub fn functionRuntimeStrict(function: *const bytecode.Bytecode) bool {
    return function.flags.is_strict or function.flags.runtime_strict;
}

pub fn ordinarySetWithReceiver(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    target: *core.Object,
    receiver_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    _ = target_value;
    if (target.proxyTarget() != null) {
        return proxySetValueProperty(ctx, output, global, receiver_value, target, atom_id, value, caller_function, caller_frame);
    }
    const receiver_object = objectFromValue(receiver_value) orelse target;
    if (try typedArrayPrototypeSet(ctx, output, global, receiver_value, receiver_object, target.getPrototype(), atom_id, value, caller_function, caller_frame)) |ok| return ok;
    if (value_ops.atomNameEql(ctx.runtime, atom_id, "__proto__")) {
        _ = try qjsObjectProtoSetterCall(ctx, output, global, receiver_value, value, caller_function, caller_frame);
        return true;
    }
    if (target.getOwnProperty(atom_id)) |own_desc| {
        defer own_desc.destroy(ctx.runtime);
        return setWithOwnDescriptor(ctx, output, global, receiver_value, atom_id, value, own_desc, caller_function, caller_frame);
    }
    if (target.getPrototype()) |prototype| {
        return ordinarySetWithReceiver(ctx, output, global, prototype.value(), prototype, receiver_value, atom_id, value, caller_function, caller_frame);
    }
    return setWithOwnDescriptor(ctx, output, global, receiver_value, atom_id, value, core.Descriptor.data(core.JSValue.undefinedValue(), true, true, true), caller_function, caller_frame);
}

pub fn qjsReflectSetCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const set_value = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    if (object.class_id == core.class.ids.module_ns) return core.JSValue.boolean(false);
    if (!object.is_array or atom_id != core.atom.ids.length) {
        const receiver_value = if (args.len >= 4) args[3] else args[0];
        if (object.proxyTarget() != null) {
            const ok = try proxySetValueProperty(ctx, output, global, receiver_value, object, atom_id, set_value, caller_function, caller_frame);
            return core.JSValue.boolean(ok);
        }
        if (builtins.buffer.isTypedArrayObject(object)) {
            switch (try typedArrayCanonicalNumericIndex(ctx.runtime, atom_id)) {
                .none => {},
                .invalid => {
                    if (sameObjectIdentity(receiver_value, args[0])) {
                        const coerced = try coerceTypedArrayElementInput(ctx, output, global, set_value);
                        defer coerced.free(ctx.runtime);
                        try builtins.buffer.typedArrayCoerceElementValue(ctx.runtime, object, coerced);
                    }
                    return core.JSValue.boolean(true);
                },
                .index => |index| {
                    if (sameObjectIdentity(receiver_value, args[0])) {
                        const coerced = try coerceTypedArrayElementForSet(ctx, output, global, object, set_value);
                        defer coerced.free(ctx.runtime);
                        if (!try builtins.buffer.typedArrayIndexValid(ctx.runtime, object, index)) return core.JSValue.boolean(true);
                        if (try builtins.buffer.typedArrayImmutableBuffer(ctx.runtime, object)) return core.JSValue.boolean(false);
                        _ = try builtins.buffer.typedArraySetElement(ctx.runtime, object, index, coerced);
                        return core.JSValue.boolean(true);
                    }
                    if (!try builtins.buffer.typedArrayIndexValid(ctx.runtime, object, index)) return core.JSValue.boolean(true);
                    const receiver_object = objectFromValue(receiver_value) orelse return core.JSValue.boolean(false);
                    const ok = try typedArrayReflectSetReceiverOwn(ctx, output, global, receiver_value, receiver_object, atom_id, set_value, caller_function, caller_frame);
                    return core.JSValue.boolean(ok);
                },
            }
        }
        if (objectFromValue(receiver_value)) |receiver_object| {
            if (try typedArrayPrototypeSet(ctx, output, global, receiver_value, receiver_object, object.getPrototype(), atom_id, set_value, caller_function, caller_frame)) |ok| {
                return core.JSValue.boolean(ok);
            }
        }
        const ok = try ordinarySetWithReceiver(ctx, output, global, args[0], object, receiver_value, atom_id, set_value, caller_function, caller_frame);
        return core.JSValue.boolean(ok);
    }
    const value_to_set = try arrayLengthAssignmentValue(ctx, output, global, object, atom_id, set_value, caller_function, caller_frame);
    defer if (!value_to_set.same(set_value)) value_to_set.free(ctx.runtime);
    object.setProperty(ctx.runtime, atom_id, value_to_set) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible, error.IncompatibleDescriptor => return core.JSValue.boolean(false),
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
    return core.JSValue.boolean(true);
}

pub fn qjsDefinePropertiesCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const target = property_ops.expectObject(args[0]) catch return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not an object"));
    try qjsDefinePropertiesOnTarget(ctx, output, global, target, args[1], caller_function, caller_frame);
    return args[0].dup();
}

const math_ops = @import("math_ops.zig");
pub const qjsMathSumPrecise = math_ops.qjsMathSumPrecise;
pub const exactF64Sum = math_ops.exactF64Sum;
pub const exactF64ScaledInteger = math_ops.exactF64ScaledInteger;
pub const scaledIntegerToF64 = math_ops.scaledIntegerToF64;
pub const shouldRoundScaledIntegerUp = math_ops.shouldRoundScaledIntegerUp;

pub const IntegrityLevel = enum {
    sealed,
    frozen,
};

pub fn qjsReflectIsExtensibleCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    if (!args[0].isObject()) return error.TypeError;
    return qjsObjectIsExtensibleCall(ctx, output, global, args, caller_function, caller_frame);
}

pub fn qjsReflectPreventExtensionsCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const object = objectFromValue(args[0]) orelse return error.TypeError;
    if (object.proxyTarget() != null) {
        return core.JSValue.boolean(try proxyAwarePreventExtensions(ctx, output, global, object, caller_function, caller_frame));
    }
    object.preventExtensions();
    return core.JSValue.boolean(true);
}

pub fn qjsReflectConstructCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2 or !isConstructorLike(ctx, args[0])) return error.TypeError;
    const new_target = if (args.len >= 3) args[2] else args[0];
    if (!isConstructorLike(ctx, new_target)) return error.TypeError;
    var construct_args = try argsFromArrayLike(ctx, output, global, args[1], caller_function, caller_frame);
    defer freeArgs(ctx.runtime, construct_args);
    var construct_args_root = ValueSliceRoot{};
    construct_args_root.init(ctx.runtime, &construct_args);
    defer construct_args_root.deinit();
    if (objectFromValue(args[0])) |target| {
        if (target.proxyTarget() == null) {
            const target_name = try call_mod.nativeFunctionNameForVm(ctx.runtime, target);
            defer ctx.runtime.memory.allocator.free(target_name);
            if (construct_mod.typedArrayElement(target_name) != null) {
                try qjsTypedArrayValidateConstructArgsPreAllocate(ctx, output, global, construct_args);
            }
        }
    }
    return try constructValueOrBytecodeWithNewTarget(ctx, output, global, args[0], construct_args, caller_function, caller_frame, new_target);
}

pub const ReflectConstructResolution = struct {
    target: core.JSValue,
    new_target: core.JSValue,
    args: []const core.JSValue,
    owned_args: []core.JSValue = &.{},
};

pub fn qjsReflectConstructGenericCallable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    new_target_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const resolved = try qjsReflectConstructResolveBound(ctx.runtime, target_value, new_target_value, args);
    defer if (resolved.owned_args.len != 0) freeArgs(ctx.runtime, resolved.owned_args);
    var rooted_owned_args = resolved.owned_args;
    var owned_args_root = ValueSliceRoot{};
    if (rooted_owned_args.len != 0) owned_args_root.init(ctx.runtime, &rooted_owned_args);
    defer owned_args_root.deinit();
    const resolved_args: []const core.JSValue = if (rooted_owned_args.len != 0) rooted_owned_args else resolved.args;

    if (objectFromValue(resolved.target)) |target_object| {
        const target_name = call_mod.nativeFunctionNameForVm(ctx.runtime, target_object) catch "";
        defer if (target_name.len != 0) ctx.runtime.memory.allocator.free(target_name);
        if (std.mem.eql(u8, target_name, "Array")) {
            const prototype = try reflectConstructPrototypeVm(ctx, output, global, "Array", resolved.new_target, caller_function, caller_frame);
            return try builtins.array.constructConstructorWithPrototype(ctx.runtime, resolved_args, prototype);
        }
    }

    const prototype = try reflectConstructPrototypeVm(ctx, output, global, "Object", resolved.new_target, caller_function, caller_frame);

    if (objectFromValue(resolved.target)) |proxy| {
        if (proxy.proxyTarget() != null) {
            return try constructProxy(ctx, output, global, resolved.target, proxy, resolved_args, caller_function, caller_frame, resolved.new_target);
        }
    }

    if (resolved.target.isFunctionBytecode()) {
        const fb = functionBytecodeFromValue(resolved.target) orelse return error.TypeError;
        if (fb.is_arrow_function or !fb.has_prototype or fb.func_kind == .generator or fb.func_kind == .async_generator) {
            return error.TypeError;
        }
        const instance_object = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
        const instance = instance_object.value();
        errdefer instance.free(ctx.runtime);
        if (!fb.is_derived_class_constructor) {
            try initializeClassInstanceElements(ctx, output, global, resolved.target, instance, fb, caller_function, caller_frame);
        }
        const initial_this = if (fb.is_derived_class_constructor) core.JSValue.uninitialized() else instance;
        const constructor_this = if (fb.is_derived_class_constructor) instance else core.JSValue.undefinedValue();
        const result = try callFunctionBytecodeConstruct(ctx, resolved.target, resolved.target, initial_this, resolved_args, &.{}, output, global, &.{}, &.{}, resolved.new_target, constructor_this);
        defer result.free(ctx.runtime);
        if (result.isObject()) {
            instance.free(ctx.runtime);
            return result.dup();
        }
        return instance;
    }

    if (functionObjectFromValue(resolved.target)) |function_object| {
        const function_value = function_object.functionBytecodeSlot().* orelse return error.TypeError;
        const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
        if (fb.is_arrow_function or !fb.has_prototype or fb.func_kind == .generator or fb.func_kind == .async_generator) {
            return error.TypeError;
        }
        const instance_object = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
        const instance = instance_object.value();
        errdefer instance.free(ctx.runtime);
        if (!fb.is_derived_class_constructor) {
            try initializeClassInstanceElements(ctx, output, global, resolved.target, instance, fb, caller_function, caller_frame);
        }
        const function_global = objectRealmGlobal(function_object) orelse global;
        const initial_this = if (fb.is_derived_class_constructor) core.JSValue.uninitialized() else instance;
        const constructor_this = if (fb.is_derived_class_constructor) instance else core.JSValue.undefinedValue();
        const result = try callFunctionBytecodeConstruct(ctx, function_value, resolved.target, initial_this, resolved_args, function_object.functionCapturesSlot().*, output, function_global, function_object.functionEvalLocalNamesSlot().*, function_object.functionEvalLocalRefsSlot().*, resolved.new_target, constructor_this);
        defer result.free(ctx.runtime);
        if (result.isObject()) {
            instance.free(ctx.runtime);
            return result.dup();
        }
        return instance;
    }

    return null;
}

pub fn qjsReflectHasCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = objectFromValue(args[0]) orelse return error.TypeError;
    const key = try toPropertyKeyAtom(ctx, output, global, args[1], caller_function, caller_frame);
    defer ctx.runtime.atoms.free(key);
    const found = if (object.proxyTarget() != null)
        try hasValueProperty(ctx, output, global, args[0], object, key, caller_function, caller_frame)
    else
        try ordinaryHasValueProperty(ctx, output, global, object, key, false, caller_function, caller_frame);
    return core.JSValue.boolean(found);
}

pub fn qjsReflectApplyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len < 3 or !isCallableValue(args[0])) return error.TypeError;
    var apply_args = try argsFromArrayLike(ctx, output, global, args[2], caller_function, caller_frame);
    defer freeArgs(ctx.runtime, apply_args);
    var apply_args_root = ValueSliceRoot{};
    apply_args_root.init(ctx.runtime, &apply_args);
    defer apply_args_root.deinit();
    return callValueOrBytecode(ctx, output, global, args[1], args[0], apply_args, caller_function, caller_frame);
}

pub fn closeIteratorForFromEntriesAbrupt(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, iterator_value, return_key, null, null);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) return;
    if (!isCallableValue(return_method)) return error.TypeError;
    const out = try callValueOrBytecode(ctx, output, global, iterator_value, return_method, &.{}, null, null);
    out.free(ctx.runtime);
}

pub fn qjsDefinePropertiesOnTarget(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    properties_arg: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (properties_arg.isNull() or properties_arg.isUndefined()) return error.TypeError;
    const properties_value = if (objectFromValue(properties_arg)) |_| properties_arg.dup() else try primitiveObjectForAccess(ctx.runtime, global, properties_arg);
    defer properties_value.free(ctx.runtime);
    const properties = objectFromValue(properties_value) orelse return error.TypeError;

    const keys = try objectRestOwnKeys(ctx, output, global, properties);
    defer core.Object.freeKeys(ctx.runtime, keys);

    var pending = std.ArrayList(PendingPropertyDescriptor).empty;
    defer {
        for (pending.items) |item| item.destroy(ctx.runtime);
        pending.deinit(ctx.runtime.memory.allocator);
    }

    for (keys) |key| {
        const prop_desc = try objectRestOwnPropertyDescriptor(ctx, output, global, properties, key) orelse continue;
        defer prop_desc.destroy(ctx.runtime);
        if (prop_desc.enumerable != true) continue;

        const desc_value = try getValueProperty(ctx, output, global, properties_value, key, caller_function, caller_frame);
        defer desc_value.free(ctx.runtime);
        const desc_object = objectFromValue(desc_value) orelse return error.TypeError;
        const desc = try qjsDescriptorFromObject(ctx, output, global, desc_value, desc_object, target, key, caller_function, caller_frame);
        errdefer desc.destroy(ctx.runtime);
        const pending_key = ctx.runtime.atoms.dup(key);
        var pending_key_owned = true;
        errdefer if (pending_key_owned) ctx.runtime.atoms.free(pending_key);
        try pending.append(ctx.runtime.memory.allocator, .{ .atom_id = pending_key, .desc = desc });
        pending_key_owned = false;
    }

    for (pending.items) |item| {
        const defined = if (target.proxyTarget() != null)
            proxyDefineOwnProperty(ctx, output, global, target, item.atom_id, item.desc, caller_function, caller_frame) catch |err| switch (err) {
                error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                error.InvalidLength => return error.RangeError,
                else => return err,
            }
        else blk: {
            if (try builtins.buffer.typedArrayDefineOwnProperty(ctx.runtime, target, item.atom_id, item.desc)) |ok| {
                break :blk ok;
            } else {
                target.defineOwnProperty(ctx.runtime, item.atom_id, item.desc) catch |err| switch (err) {
                    error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                    error.InvalidLength => return error.RangeError,
                    else => return err,
                };
                break :blk true;
            }
        };
        if (!defined) return error.TypeError;
    }
}

pub fn qjsReflectGetCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = objectFromValue(args[0]) orelse return error.TypeError;
    const atom_id = try toPropertyKeyAtom(ctx, output, global, args[1], caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    const receiver = if (args.len >= 3) args[2] else args[0];
    return try getValuePropertyWithReceiver(ctx, output, global, args[0], object, receiver, atom_id, caller_function, caller_frame);
}

pub fn qjsReflectOwnKeysCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const object = property_ops.expectObject(args[0]) catch return error.TypeError;
    const keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, keys);
    const out = try core.Object.createArray(ctx.runtime, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    for (keys) |key| {
        const key_value = try proxyTrapKeyValue(ctx.runtime, key);
        defer key_value.free(ctx.runtime);
        try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(out.length), core.Descriptor.data(key_value, true, true, true));
    }
    return out.value();
}

pub fn callAccessorSetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (try findPropertyDescriptor(object, atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        if (desc.kind != .accessor) return false;
        if (desc.setter.isUndefined()) return error.AccessorWithoutSetter;
        const result = try callValueOrBytecode(ctx, output, global, receiver, desc.setter, &.{value}, caller_function, caller_frame);
        result.free(ctx.runtime);
        return true;
    }
    return false;
}

pub fn clearPrivateNameRemap(rt: *core.JSRuntime, object: *core.Object) void {
    if (object.privateRemapFrom().len == 0 and object.privateRemapTo().len == 0) return;
    const from_slot = object.privateRemapFromSlot();
    const to_slot = object.privateRemapToSlot();
    const old_from = from_slot.*;
    const old_to = to_slot.*;
    from_slot.* = &.{};
    to_slot.* = &.{};
    for (old_from) |atom_id| rt.atoms.free(atom_id);
    if (old_from.len != 0) rt.memory.free(core.Atom, old_from);
    for (old_to) |atom_id| rt.atoms.free(atom_id);
    if (old_to.len != 0) rt.memory.free(core.Atom, old_to);
}

pub const PrivateNameRemapSnapshot = struct {
    from: []core.Atom = &.{},
    to: []core.Atom = &.{},

    pub fn capture(rt: *core.JSRuntime, object: *const core.Object) !PrivateNameRemapSnapshot {
        const old_from = object.privateRemapFrom();
        const old_to = object.privateRemapTo();
        std.debug.assert(old_from.len == old_to.len);
        if (old_from.len == 0) return .{};

        const from = try rt.memory.alloc(core.Atom, old_from.len);
        errdefer rt.memory.free(core.Atom, from);
        const to = try rt.memory.alloc(core.Atom, old_to.len);
        errdefer rt.memory.free(core.Atom, to);

        for (old_from, 0..) |atom_id, index| from[index] = rt.atoms.dup(atom_id);
        for (old_to, 0..) |atom_id, index| to[index] = rt.atoms.dup(atom_id);
        return .{ .from = from, .to = to };
    }

    pub fn restore(self: *PrivateNameRemapSnapshot, rt: *core.JSRuntime, object: *core.Object) void {
        clearPrivateNameRemap(rt, object);
        if (self.from.len != 0) {
            object.privateRemapFromSlot().* = self.from;
            object.privateRemapToSlot().* = self.to;
            self.from = &.{};
            self.to = &.{};
        }
    }

    pub fn deinit(self: *PrivateNameRemapSnapshot, rt: *core.JSRuntime) void {
        for (self.from) |atom_id| rt.atoms.free(atom_id);
        if (self.from.len != 0) rt.memory.free(core.Atom, self.from);
        for (self.to) |atom_id| rt.atoms.free(atom_id);
        if (self.to.len != 0) rt.memory.free(core.Atom, self.to);
        self.from = &.{};
        self.to = &.{};
    }
};

pub fn appendPrivateNameRemap(rt: *core.JSRuntime, object: *core.Object, from_atom: core.Atom, to_atom: core.Atom) !void {
    const from_slot = try object.privateRemapFromSlotEnsured(rt);
    const to_slot = try object.privateRemapToSlotEnsured(rt);
    for (from_slot.*, 0..) |existing, idx| {
        if (existing != from_atom) continue;
        const retained = rt.atoms.dup(to_atom);
        const old = to_slot.*[idx];
        to_slot.*[idx] = retained;
        rt.atoms.free(old);
        return;
    }

    const new_len = from_slot.*.len + 1;
    const from = try rt.memory.alloc(core.Atom, new_len);
    errdefer rt.memory.free(core.Atom, from);
    const to = try rt.memory.alloc(core.Atom, new_len);
    errdefer rt.memory.free(core.Atom, to);
    @memcpy(from[0..from_slot.*.len], from_slot.*);
    @memcpy(to[0..to_slot.*.len], to_slot.*);
    from[new_len - 1] = rt.atoms.dup(from_atom);
    to[new_len - 1] = rt.atoms.dup(to_atom);
    const old_from = from_slot.*;
    const old_to = to_slot.*;
    from_slot.* = from;
    to_slot.* = to;
    if (old_from.len != 0) rt.memory.free(core.Atom, old_from);
    if (old_to.len != 0) rt.memory.free(core.Atom, old_to);
}

pub fn installLexicalPrivateNameRemap(
    rt: *core.JSRuntime,
    object: *core.Object,
    caller_frame: ?*frame_mod.Frame,
    bound_names: []const core.Atom,
) !void {
    if (bound_names.len == 0) return;
    var snapshot = try PrivateNameRemapSnapshot.capture(rt, object);
    defer snapshot.deinit(rt);
    errdefer snapshot.restore(rt, object);

    for (bound_names) |atom_id| {
        const mapped = remapPrivateAtomFromFrame(rt, caller_frame, atom_id);
        if (mapped != atom_id) try appendPrivateNameRemap(rt, object, atom_id, mapped);
    }
}

pub fn installFreshPrivateNameRemap(rt: *core.JSRuntime, object: *core.Object, old_names: []const core.Atom) !void {
    if (old_names.len == 0) return;
    var snapshot = try PrivateNameRemapSnapshot.capture(rt, object);
    defer snapshot.deinit(rt);
    errdefer snapshot.restore(rt, object);

    for (old_names) |old_atom| {
        const name = rt.atoms.name(old_atom) orelse return error.TypeError;
        const fresh_atom = try rt.atoms.newSymbol(name, .private);
        defer rt.atoms.free(fresh_atom);
        try appendPrivateNameRemap(rt, object, old_atom, fresh_atom);
    }
}

pub fn copyPrivateNameRemap(rt: *core.JSRuntime, dst: *core.Object, src: *const core.Object) !void {
    if (src.privateRemapFrom().len == 0) return;
    const from = try rt.memory.alloc(core.Atom, src.privateRemapFrom().len);
    errdefer rt.memory.free(core.Atom, from);
    const to = try rt.memory.alloc(core.Atom, src.privateRemapTo().len);
    errdefer rt.memory.free(core.Atom, to);
    var initialized: usize = 0;
    errdefer {
        for (from[0..initialized]) |atom_id| rt.atoms.free(atom_id);
        for (to[0..initialized]) |atom_id| rt.atoms.free(atom_id);
    }
    for (src.privateRemapFrom(), 0..) |atom_id, idx| {
        from[idx] = rt.atoms.dup(atom_id);
        to[idx] = rt.atoms.dup(src.privateRemapTo()[idx]);
        initialized += 1;
    }
    const from_slot = try dst.privateRemapFromSlotEnsured(rt);
    const to_slot = try dst.privateRemapToSlotEnsured(rt);
    const old_from = from_slot.*;
    const old_to = to_slot.*;
    from_slot.* = from;
    to_slot.* = to;
    for (old_from) |atom_id| rt.atoms.free(atom_id);
    if (old_from.len != 0) rt.memory.free(core.Atom, old_from);
    for (old_to) |atom_id| rt.atoms.free(atom_id);
    if (old_to.len != 0) rt.memory.free(core.Atom, old_to);
}

pub fn remapPrivateAtomFromFrame(rt: *core.JSRuntime, caller_frame: ?*frame_mod.Frame, atom_id: core.Atom) core.Atom {
    if (rt.atoms.kind(atom_id) != .private) return atom_id;
    const frame = caller_frame orelse return atom_id;
    const function_object = objectFromValue(frame.current_function) orelse return atom_id;
    const function_atom = remapPrivateAtomFromObject(rt, function_object, atom_id);
    if (function_atom != atom_id) return function_atom;
    const home_object = function_object.functionHomeObjectSlot().* orelse return atom_id;
    return remapPrivateAtomFromObject(rt, home_object, atom_id);
}

pub fn remapPrivateAtomForOperation(
    rt: *core.JSRuntime,
    caller_frame: ?*frame_mod.Frame,
    object: ?*const core.Object,
    atom_id: core.Atom,
) core.Atom {
    const frame_atom = remapPrivateAtomFromFrame(rt, caller_frame, atom_id);
    if (frame_atom != atom_id) return frame_atom;
    if (object) |target| return remapPrivateAtomFromObject(rt, target, atom_id);
    return atom_id;
}

pub fn inOp(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rhs = try stack.pop();
    defer rhs.free(ctx.runtime);
    const lhs = try stack.pop();
    defer lhs.free(ctx.runtime);
    const object = property_ops.expectObject(rhs) catch return error.TypeError;
    const key = try toPropertyKeyAtom(ctx, output, global, lhs, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(key);
    const has_builtin_object_proto = value_ops.atomNameEql(ctx.runtime, key, "toString") and (object.class_id == core.class.ids.object or object.is_array);
    const found = if (object.proxyTarget() != null)
        try hasValueProperty(ctx, output, global, rhs, object, key, caller_function, caller_frame)
    else
        try ordinaryHasValueProperty(ctx, output, global, object, key, has_builtin_object_proto, caller_function, caller_frame);
    try stack.pushOwned(core.JSValue.boolean(found));
}

pub fn instanceofOp(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const rhs = try stack.pop();
    defer rhs.free(ctx.runtime);
    const lhs = try stack.pop();
    defer lhs.free(ctx.runtime);
    const ctor = property_ops.expectObject(rhs) catch return error.TypeError;
    const has_instance_atom = core.atom.predefinedId("Symbol.hasInstance", .symbol) orelse return error.TypeError;
    const has_instance = try getValueProperty(ctx, output, global, rhs, has_instance_atom, caller_function, caller_frame);
    defer has_instance.free(ctx.runtime);
    if (!has_instance.isUndefined() and !has_instance.isNull()) {
        const result = try callValueOrBytecode(ctx, output, global, rhs, has_instance, &.{lhs}, caller_function, caller_frame);
        defer result.free(ctx.runtime);
        try stack.pushOwned(core.JSValue.boolean(valueTruthy(result)));
        return;
    }
    if (!isCallableValue(rhs)) return error.TypeError;
    if (!lhs.isObject()) {
        try stack.pushOwned(core.JSValue.boolean(false));
        return;
    }
    const object = try property_ops.expectObject(lhs);
    if (try constructorNameEqlLocal(ctx.runtime, ctor, "Array")) {
        try stack.pushOwned(core.JSValue.boolean(object.is_array));
        return;
    }
    const proto_value = try getValueProperty(ctx, output, global, rhs, core.atom.ids.prototype, caller_function, caller_frame);
    defer proto_value.free(ctx.runtime);
    if (!proto_value.isObject()) {
        return error.TypeError;
    }
    const proto = try property_ops.expectObject(proto_value);
    var current = try qjsObjectGetPrototypeOfStep(ctx, output, global, object, caller_function, caller_frame);
    while (current) |candidate| {
        if (candidate == proto) {
            try stack.pushOwned(core.JSValue.boolean(true));
            return;
        }
        current = try qjsObjectGetPrototypeOfStep(ctx, output, global, candidate, caller_function, caller_frame);
    }
    try stack.pushOwned(core.JSValue.boolean(false));
}

pub fn constructorNameEqlLocal(rt: *core.JSRuntime, object: *core.Object, expected: []const u8) !bool {
    const name_value = nativeFunctionNameValueLocal(rt, object) catch return false;
    defer name_value.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &bytes, name_value);
    return std.mem.eql(u8, bytes.items, expected);
}

pub fn nativeFunctionNameValueLocal(rt: *core.JSRuntime, object: *core.Object) !core.JSValue {
    const dispatch_atom = object.nativeDispatchName();
    if (dispatch_atom != core.atom.null_atom) {
        const dispatch_name = try rt.atoms.toStringValue(rt, dispatch_atom);
        if (dispatch_name.isString()) return dispatch_name;
        dispatch_name.free(rt);
    }
    const name_value = object.getProperty(core.atom.ids.name);
    if (!name_value.isString()) {
        name_value.free(rt);
        return error.TypeError;
    }
    return name_value;
}

pub fn isBlockedByUnscopables(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const unscopables_atom = core.atom.predefinedId("Symbol.unscopables", .symbol) orelse return false;
    const unscopables = try getValueProperty(ctx, output, global, object_value, unscopables_atom, caller_function, caller_frame);
    defer unscopables.free(ctx.runtime);
    if (!unscopables.isObject()) return false;
    const blocked = try getValueProperty(ctx, output, global, unscopables, atom_id, caller_function, caller_frame);
    defer blocked.free(ctx.runtime);
    return valueTruthy(blocked);
}

pub fn lookupFrameVarRef(rt: *core.JSRuntime, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, atom_id: core.Atom) ?core.JSValue {
    return lookupNamedVarRef(rt, function.var_ref_names, frame.var_refs, atom_id);
}

pub fn lookupFrameLocalValue(rt: *core.JSRuntime, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, atom_id: core.Atom) ?core.JSValue {
    const count = @min(function.var_names.len, frame.locals.len);
    for (function.var_names[0..count], 0..) |name, idx| {
        if (!atomIdOrNameEql(rt, name, atom_id)) continue;
        return slotValueDup(frame.locals[idx]);
    }
    return null;
}

pub fn lookupEvalBindingValue(
    rt: *core.JSRuntime,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
) ?core.JSValue {
    if (lookupNamedSlotValue(rt, eval_local_names, eval_local_slots, atom_id)) |value| return value;
    if (!frame.eval_var_refs_republished) {
        if (lookupNamedVarRef(rt, eval_var_ref_names, eval_var_refs, atom_id)) |value| return value;
    }
    if (lookupNamedSlotValue(rt, frame.eval_local_names, frame.eval_local_slots, atom_id)) |value| return value;
    if (lookupNamedVarRef(rt, frame.eval_var_ref_names, frame.eval_var_refs, atom_id)) |value| return value;
    return null;
}

pub fn lookupFrameFirstEvalBindingValue(
    rt: *core.JSRuntime,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
) ?core.JSValue {
    if (lookupNamedSlotValue(rt, frame.eval_local_names, frame.eval_local_slots, atom_id)) |value| return value;
    if (lookupNamedVarRef(rt, frame.eval_var_ref_names, frame.eval_var_refs, atom_id)) |value| return value;
    if (lookupNamedSlotValue(rt, eval_local_names, eval_local_slots, atom_id)) |value| return value;
    if (!frame.eval_var_refs_republished) {
        if (lookupNamedVarRef(rt, eval_var_ref_names, eval_var_refs, atom_id)) |value| return value;
    }
    return null;
}

pub fn lookupParentFunctionEvalBindingValue(
    rt: *core.JSRuntime,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
) ?core.JSValue {
    const function_object = objectFromValue(frame.current_function) orelse return null;
    const parent_value = function_object.functionEvalParentFunction() orelse return null;
    const parent_object = objectFromValue(parent_value) orelse return null;
    return lookupNamedVarRef(rt, parent_object.functionEvalLocalNamesSlot().*, parent_object.functionEvalLocalRefsSlot().*, atom_id);
}

pub fn atomIdOrNameEql(rt: *core.JSRuntime, left: core.Atom, right: core.Atom) bool {
    if (left == right) return true;
    const left_name = rt.atoms.name(left) orelse return false;
    const right_name = rt.atoms.name(right) orelse return false;
    return std.mem.eql(u8, left_name, right_name);
}

pub fn lookupNamedVarRef(rt: *core.JSRuntime, names: []const core.Atom, refs: []const core.JSValue, atom_id: core.Atom) ?core.JSValue {
    for (names, 0..) |name, idx| {
        if (!atomIdOrNameEql(rt, name, atom_id) or idx >= refs.len) continue;
        if (varRefSlotIsDeleted(refs[idx])) return core.JSValue.uninitialized();
        return slotValueDup(refs[idx]);
    }
    return null;
}

pub fn deleteEvalBinding(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    atom_id: core.Atom,
) ?bool {
    if (value_ops.atomNameEql(rt, function.name, "<eval>")) {
        if (deleteFrameLocalBinding(rt, function, frame, atom_id)) |deleted| return deleted;
    }
    if (deleteNamedSlotBinding(rt, eval_local_names, eval_local_slots, atom_id)) |deleted| return deleted;
    if (!frame.eval_var_refs_republished) {
        if (deleteNamedVarRefBinding(rt, eval_var_ref_names, eval_var_refs, atom_id)) |deleted| return deleted;
    }
    if (deleteNamedSlotBinding(rt, frame.eval_local_names, frame.eval_local_slots, atom_id)) |deleted| return deleted;
    if (deleteNamedVarRefBinding(rt, frame.eval_var_ref_names, frame.eval_var_refs, atom_id)) |deleted| return deleted;
    return null;
}

pub fn deleteFrameLocalBinding(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
) ?bool {
    const count = @min(@min(function.var_names.len, function.var_is_lexical.len), frame.locals.len);
    for (function.var_names[0..count], 0..) |name, idx| {
        if (!atomIdOrNameEql(rt, name, atom_id)) continue;
        if (function.var_is_lexical[idx]) return false;
        return deleteVarRefSlot(rt, frame.locals[idx]);
    }
    return null;
}

pub fn deleteNamedSlotBinding(rt: *core.JSRuntime, names: []const core.Atom, slots: []const core.JSValue, atom_id: core.Atom) ?bool {
    for (names, 0..) |name, idx| {
        if (!atomIdOrNameEql(rt, name, atom_id) or idx >= slots.len) continue;
        return deleteVarRefSlot(rt, slots[idx]);
    }
    return null;
}

pub fn deleteNamedVarRefBinding(rt: *core.JSRuntime, names: []const core.Atom, refs: []const core.JSValue, atom_id: core.Atom) ?bool {
    for (names, 0..) |name, idx| {
        if (!atomIdOrNameEql(rt, name, atom_id) or idx >= refs.len) continue;
        return deleteVarRefSlot(rt, refs[idx]);
    }
    return null;
}

pub fn deleteVarRefSlot(rt: *core.JSRuntime, slot: core.JSValue) ?bool {
    const cell = varRefCellFromValue(slot) orelse return false;
    if (cell.varRefIsDeletedSlot().*) return null;
    if (!cell.varRefIsDeletableSlot().*) return false;
    const old_value = cell.varRefValueSlot().*;
    cell.varRefValueSlot().* = core.JSValue.undefinedValue();
    cell.varRefIsDeletedSlot().* = true;
    if (old_value) |stored| stored.free(rt);
    return true;
}

pub fn lookupNamedSlotValue(rt: *core.JSRuntime, names: []const core.Atom, slots: []const core.JSValue, atom_id: core.Atom) ?core.JSValue {
    for (names, 0..) |name, idx| {
        if (!atomIdOrNameEql(rt, name, atom_id) or idx >= slots.len) continue;
        if (varRefSlotIsDeleted(slots[idx])) return core.JSValue.uninitialized();
        return slotValueDup(slots[idx]);
    }
    return null;
}

pub fn lookupNamedRawSlotValue(rt: *core.JSRuntime, names: []const core.Atom, slots: []const core.JSValue, atom_id: core.Atom) ?core.JSValue {
    for (names, 0..) |name, idx| {
        if (!atomIdOrNameEql(rt, name, atom_id) or idx >= slots.len) continue;
        if (varRefSlotIsDeleted(slots[idx])) continue;
        return slots[idx].dup();
    }
    return null;
}

pub fn initializeEvalFrameLocals(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    names: []const core.Atom,
    slots: []const core.JSValue,
) void {
    const count = @min(function.var_names.len, frame.locals.len);
    for (function.var_names[0..count], 0..) |atom_id, idx| {
        if (idx < function.var_is_lexical.len and function.var_is_lexical[idx]) continue;
        const value = lookupNamedRawSlotValue(ctx.runtime, names, slots, atom_id) orelse continue;
        const old_value = frame.locals[idx];
        frame.locals[idx] = value;
        old_value.free(ctx.runtime);
    }
}

pub fn setNamedSlotValue(ctx: *core.JSContext, names: []const core.Atom, slots: []core.JSValue, atom_id: core.Atom, value: core.JSValue) !bool {
    for (names, 0..) |name, idx| {
        if (!atomIdOrNameEql(ctx.runtime, name, atom_id) or idx >= slots.len) continue;
        try setSlotValue(ctx, &slots[idx], value);
        return true;
    }
    return false;
}

pub fn setFrameLocalValue(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
    value: core.JSValue,
) !bool {
    const count = @min(function.var_names.len, frame.locals.len);
    for (function.var_names[0..count], 0..) |name, idx| {
        if (name != atom_id) continue;
        if (idx < function.var_is_lexical.len and function.var_is_lexical[idx]) continue;
        try setSlotValue(ctx, &frame.locals[idx], value);
        return true;
    }
    return false;
}

pub fn setFrameVarRefValue(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    atom_id: core.Atom,
    value: core.JSValue,
) !bool {
    for (function.var_ref_names, 0..) |name, idx| {
        if (name != atom_id) continue;
        if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, @intCast(idx));
        try setSlotValue(ctx, &frame.var_refs[idx], value);
        return true;
    }
    return false;
}

pub fn setNamedVarRefValue(
    ctx: *core.JSContext,
    names: []const core.Atom,
    refs: []const core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    strict_assignment: bool,
    is_init: bool,
) !bool {
    for (names, 0..) |name, idx| {
        if (!atomIdOrNameEql(ctx.runtime, name, atom_id) or idx >= refs.len) continue;
        const slot = refs[idx];
        if (varRefCellFromValue(slot)) |cell| {
            if (cell.varRefIsConstSlot().* and !is_init) {
                value.free(ctx.runtime);
                if (cell.varRefIsFunctionNameSlot().* and !strict_assignment) return true;
                return error.TypeError;
            }
            errdefer value.free(ctx.runtime);
            try cell.setVarRefValue(ctx.runtime, value);
            return true;
        }
        return false;
    }
    return false;
}

pub fn functionNameValueFromAtom(rt: *core.JSRuntime, atom_id: core.Atom, prefix: ?[]const u8) !core.JSValue {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    if (prefix) |text| {
        try bytes.appendSlice(rt.memory.allocator, text);
        try bytes.append(rt.memory.allocator, ' ');
    }
    if (core.atom.isTaggedInt(atom_id)) {
        var buf: [10]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{core.atom.atomToUInt32(atom_id)});
        try bytes.appendSlice(rt.memory.allocator, text);
        return value_ops.createStringValue(rt, bytes.items);
    }
    const atom_name = rt.atoms.name(atom_id) orelse "";
    if (rt.atoms.kind(atom_id) == .symbol) {
        if (builtins.symbol.description(&rt.atoms, atom_id)) |description| {
            try bytes.append(rt.memory.allocator, '[');
            try bytes.appendSlice(rt.memory.allocator, description);
            try bytes.append(rt.memory.allocator, ']');
        }
    } else {
        try bytes.appendSlice(rt.memory.allocator, atom_name);
    }
    return value_ops.createStringValue(rt, bytes.items);
}

pub fn mappedArgumentsValue(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) ?core.JSValue {
    if (object.class_id != core.class.ids.mapped_arguments) return null;
    const index = core.array.arrayIndexFromAtom(&rt.atoms, atom_id) orelse return null;
    const refs = object.argumentsVarRefs();
    if (index >= refs.len) return null;
    if (refs[index].isUninitialized()) return null;
    if (!object.hasOwnProperty(atom_id)) return null;
    const cell = varRefCellFromValue(refs[index]) orelse return refs[index].dup();
    return if (cell.varRefValueSlot().*) |value| value.dup() else core.JSValue.undefinedValue();
}

pub fn setMappedArgumentsValue(ctx: *core.JSContext, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !bool {
    if (object.class_id != core.class.ids.mapped_arguments) return false;
    const index = core.array.arrayIndexFromAtom(&ctx.runtime.atoms, atom_id) orelse return false;
    const refs = object.argumentsVarRefsSlot();
    if (index >= refs.*.len) return false;
    if (refs.*[index].isUninitialized()) return false;
    if (!object.hasOwnProperty(atom_id)) {
        const old_value = refs.*[index];
        refs.*[index] = core.JSValue.uninitialized();
        old_value.free(ctx.runtime);
        return false;
    }
    if (varRefCellFromValue(refs.*[index])) |cell| {
        const next_value = value.dup();
        try cell.setVarRefValue(ctx.runtime, next_value);
        return true;
    }
    const next_value = value.dup();
    errdefer next_value.free(ctx.runtime);
    try ctx.runtime.writeBarrierValueAt(&object.header, next_value, &refs.*[index]);
    const old_value = refs.*[index];
    refs.*[index] = next_value;
    old_value.free(ctx.runtime);
    return true;
}

pub fn throwTypeErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx.runtime, global, "TypeError", message);
    var error_value_owned = true;
    errdefer if (error_value_owned) error_value.free(ctx.runtime);
    try attachStackToErrorValue(ctx, global, error_value);
    _ = ctx.throwValue(error_value);
    error_value_owned = false;
    return error.TypeError;
}

pub fn throwRangeErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx.runtime, global, "RangeError", message);
    var error_value_owned = true;
    errdefer if (error_value_owned) error_value.free(ctx.runtime);
    try attachStackToErrorValue(ctx, global, error_value);
    _ = ctx.throwValue(error_value);
    error_value_owned = false;
    return error.RangeError;
}

pub fn throwReferenceErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx.runtime, global, "ReferenceError", message);
    var error_value_owned = true;
    errdefer if (error_value_owned) error_value.free(ctx.runtime);
    try attachStackToErrorValue(ctx, global, error_value);
    _ = ctx.throwValue(error_value);
    error_value_owned = false;
    return error.ReferenceError;
}

pub fn throwSyntaxErrorMessage(ctx: *core.JSContext, global: *core.Object, message: []const u8) !core.JSValue {
    const error_value = try createNamedError(ctx.runtime, global, "SyntaxError", message);
    var error_value_owned = true;
    errdefer if (error_value_owned) error_value.free(ctx.runtime);
    try attachStackToErrorValue(ctx, global, error_value);
    _ = ctx.throwValue(error_value);
    error_value_owned = false;
    return error.SyntaxError;
}

pub fn attachStackToErrorValue(ctx: *core.JSContext, global: *core.Object, value: core.JSValue) !void {
    const object = property_ops.expectObject(value) catch return;
    try captureErrorStack(ctx, null, global, object);
}

pub fn qjsErrorCaptureStackTrace(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1 or !args[0].isObject()) return throwTypeErrorMessage(ctx, global, "not an object");
    const target = try property_ops.expectObject(args[0]);
    const skip_name = if (args.len >= 2 and isCallableValue(args[1]))
        try exception_ops.functionNameBytes(ctx.runtime, args[1])
    else
        null;
    defer if (skip_name) |bytes| ctx.runtime.memory.allocator.free(bytes);
    const stack_value = try buildErrorStackValue(ctx, output, global, args[0], skip_name);
    defer stack_value.free(ctx.runtime);
    try defineDataProperty(ctx.runtime, target, "stack", stack_value, true, false, true);
    return core.JSValue.undefinedValue();
}

pub fn ensureVarRefCell(ctx: *core.JSContext, slot: *core.JSValue) !core.JSValue {
    if (varRefCellFromValue(slot.*) != null) return slot.*.dup();
    const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    try object.initVarRefPayload(ctx.runtime, slot.*);
    slot.* = object.value();
    return slot.*.dup();
}

pub fn ensureLocalVarRefCell(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize, is_lexical: bool) !core.JSValue {
    _ = is_lexical;
    if (idx < frame.locals_uninit.len and frame.localIsUninitialized(idx)) {
        if (varRefCellFromValue(frame.locals[idx])) |cell| {
            const old_value = cell.varRefValueSlot().*;
            cell.varRefValueSlot().* = core.JSValue.uninitialized();
            if (old_value) |stored| stored.free(ctx.runtime);
            return frame.locals[idx].dup();
        }
        const old_value = frame.locals[idx];
        frame.locals[idx] = core.JSValue.uninitialized();
        old_value.free(ctx.runtime);
    }
    return ensureVarRefCell(ctx, &frame.locals[idx]);
}

pub fn varRefCellFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_payload_kind != .var_ref) return null;
    return object;
}

pub fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

var worker_gpa = std.heap.DebugAllocator(.{
    .safety = false,
    .stack_trace_frames = 0,
    .retain_metadata = true,
}){};
pub fn workerPageAllocator() std.mem.Allocator {
    return worker_gpa.allocator();
}
