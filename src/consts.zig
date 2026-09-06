pub const version: u16 = 1;

pub const logLevel = enum(u8) {
    trace = 10,
    debug = 20,
    info = 30,
    warning = 40,
    err = 50,
    panic = 60,
};

pub const ValueKind = enum(u8) {
    // Group 1: special types 0..31.
    time = 0,
    duration = 1,
    errorRaw = 2,
    ivar = 16,
    uvar = 17,

    // Group 2: basic types. 32..63.
    bool = 32,
    string = 33,
    int8 = 40,
    int16 = 41,
    int32 = 42,
    int64 = 43,
    uint8 = 48,
    uint16 = 49,
    uint32 = 50,
    uint64 = 51,
    float32 = 56,
    float64 = 57,

    // Group 3: slices of basic types.
    sliceBool = 64, // или sliceBool
    sliceString = 65,
    sliceInt8 = 72,
    sliceInt16 = 73,
    sliceInt32 = 74,
    sliceInt64 = 75,
    sliceUint8 = 80,
    sliceUint16 = 81,
    sliceUint32 = 82,
    sliceUint64 = 83,
    sliceFloat32 = 88,
    sliceFloat64 = 89,

    // Group 4: tree nodes and metadata: 128..255.
    nodeNew = 128,
    nodeWrap = 129,
    nodeContext = 130,
    nodeLocation = 131,
    nodeForeignErrorText = 132,
    nodePhantomContext = 133,
    nodeGroup = 134,
    nodeError = 135,
    nodeErrorEmbed = 136,
    nodeGroupEnd = 137,
};
