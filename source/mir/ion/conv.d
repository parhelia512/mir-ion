/++
Conversion utilities.
+/
module mir.ion.conv;

public import mir.ion.internal.stage3: mir_json2ion;
import mir.ion.stream: IonValueStream;

private enum dip1000 = __traits(compiles, ()@nogc { throw new Exception(""); });

/++
Serialize value to binary ion data and deserialize it back to requested type.
Uses GC allocated string tables.
+/
template serde(T)
    if (!is(immutable T == immutable IonValueStream))
{
    import mir.serde: SerdeTarget;

    ///
    T serde(V)(auto ref const V value, int serdeTarget = SerdeTarget.ion)
    {
        T target;
        serde(target, value, serdeTarget);
        return target;
    }

    ///
    void serde(V)(scope ref T target, auto ref scope const V value, int serdeTarget = SerdeTarget.ion)
        if (!is(immutable V == immutable IonValueStream))
    {
        import mir.ion.exception;
        import mir.deser.ion: deserializeIon;
        import mir.ion.internal.data_holder: ionPrefix;
        import mir.ser: serializeValue;
        import mir.ser.ion: ionSerializer;
        import mir.ion.symbol_table: IonSymbolTable, removeSystemSymbols, IonSystemSymbolTable_v1;
        import mir.ion.value: IonValue, IonDescribedValue, IonList;
        import mir.serde: serdeGetSerializationKeysRecurse;
        import mir.utility: _expect;

        enum nMax = 4096;
        enum keys = serdeGetSerializationKeysRecurse!V.removeSystemSymbols;


        import mir.appender : scopedBuffer;
        auto symbolTableBuffer = scopedBuffer!(const(char)[]);

        auto table = () @trusted { IonSymbolTable!false ret = void; ret.initializeNull; return ret; }();
        auto serializer = ionSerializer!(nMax * 8, keys, false);
        serializer.initialize(table);
        serializeValue(serializer, value);
        serializer.finalize;

        scope const(const(char)[])[] symbolTable;

        // use runtime table
        if (table.initialized)
        {
            symbolTableBuffer.put(IonSystemSymbolTable_v1);
            foreach (IonErrorCode error, scope IonDescribedValue symbolValue; IonList(table.unfinilizedKeysData))
            {
                assert(!error);
                (()@trusted => symbolTableBuffer.put(symbolValue.trustedGet!(const(char)[])))();
            }
            symbolTable = symbolTableBuffer.data;
        }
        else
        {
            static immutable compileTimeTable = IonSystemSymbolTable_v1 ~ keys;
            symbolTable = compileTimeTable;
        }
        auto ionValue = ()@trusted {return serializer.data.IonValue.describe();}();
        return deserializeIon!T(target, symbolTable, ionValue);
    }

    /// ditto
    void serde()(scope ref T target, scope IonValueStream stream, int serdeTarget = SerdeTarget.ion)
        if (!is(immutable V == immutable IonValueStream))
    {
        import mir.deser.ion: deserializeIon;
        return deserializeIon!T(target, stream.data);
    }
}

/// ditto
template serde(T)
    if (is(T == IonValueStream))
{
    ///
    import mir.serde: SerdeTarget;
    T serde(V)(auto ref scope const V value, int serdeTarget = SerdeTarget.ion)
        if (!is(immutable V == immutable IonValueStream))
    {
        import mir.ser.ion: serializeIon;
        return serializeIon(value, serdeTarget).IonValueStream;
    }
}


///
version(mir_ion_test)
@safe
unittest {
    import mir.ion.stream: IonValueStream;
    import mir.algebraic_alias.json: JsonAlgebraic;
    static struct S
    {
        double a;
        string s;
    }
    auto s = S(12.34, "str");
    assert(s.serde!JsonAlgebraic.serde!S == s);
    assert(s.serde!IonValueStream.serde!S == s);
}

@safe pure
version(mir_ion_test)
unittest {
    static struct S
    {
        double a;
        string s;
    }
    auto s = S(12.34, "str");
    assert(s.serde!S == s);
    assert(s.serde!IonValueStream.serde!S == s);
}

/++
Converts JSON Value Stream to binary Ion data.
+/
immutable(ubyte)[] json2ion(scope const(char)[] text)
    @trusted pure
{
    pragma(inline, false);
    import mir.ion.exception: ionErrorMsg, IonParserMirException;

    immutable(ubyte)[] ret;
    mir_json2ion(text, (error, data)
    {
        if (error.code)
            throw new IonParserMirException(error.code.ionErrorMsg, error.location);
        ret = data.idup;
    });
    return ret;
}

///
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    static immutable ubyte[] data = [0xe0, 0x01, 0x00, 0xea, 0xe9, 0x81, 0x83, 0xd6, 0x87, 0xb4, 0x81, 0x62, 0x81, 0x61, 0xd6, 0x8b, 0x21, 0x01, 0x8a, 0x21, 0x02];
    `{"a":1,"b":2}`.json2ion.should == data;
}

/++
Convert an JSON value to a Ion Value Stream.

This function is the @nogc version of json2ion.
Params:
    text = The JSON to convert
    appender = A buffer that will receive the Ion binary data
+/
void json2ion(Appender)(scope const(char)[] text, scope ref Appender appender)
    @trusted pure @nogc
{
    import mir.ion.exception: ionErrorMsg, ionException, IonMirException;
    import mir.ion.internal.data_holder: ionPrefix;

    mir_json2ion(text, (error, data)
    {
        if (error.code)
        {
            enum nogc = __traits(compiles, (const(ubyte)[] data, scope ref Appender appender) @nogc { appender.put(data); });
            static if (!nogc || dip1000)
            {
                throw new IonMirException(error.code.ionErrorMsg, ". location = ", error.location, ", last input key = ", error.key);
            }
            else
            {
                throw error.code.ionException;
            }
        }
        appender.put(data);
    });
}

///
@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    import mir.appender : scopedBuffer;
    static immutable ubyte[] data = [0xe0, 0x01, 0x00, 0xea, 0xe9, 0x81, 0x83, 0xd6, 0x87, 0xb4, 0x81, 0x62, 0x81, 0x61, 0xd6, 0x8b, 0x21, 0x01, 0x8a, 0x21, 0x02];
    auto buf = scopedBuffer!ubyte;
    json2ion(` { "a" : 1, "b" : 2 } `, buf);
    buf.data.should == data;
}

/++
Converts JSON Value Stream to binary Ion data wrapped to $(SUBREF stream, IonValueStream).
+/
IonValueStream json2ionStream(scope const(char)[] text)
    @trusted pure
{
    return text.json2ion.IonValueStream;
}

///
@safe pure
version(mir_ion_test) unittest
{
    static immutable ubyte[] data = [0xe0, 0x01, 0x00, 0xea, 0xe9, 0x81, 0x83, 0xd6, 0x87, 0xb4, 0x81, 0x62, 0x81, 0x61, 0xd6, 0x8b, 0x21, 0x01, 0x8a, 0x21, 0x02];
    assert(`{"a":1,"b":2}`.json2ionStream.data == data);
}

/++
Converts Ion Value Stream data to JSON text.

The function performs `data.IonValueStream.serializeJson`.
+/
string ion2json(scope const(ubyte)[] data)
    @safe pure
{
    pragma(inline, false);
    import mir.ser.json: serializeJson;
    return data.IonValueStream.serializeJson;
}

///
@safe pure
version(mir_ion_test) unittest
{
    static immutable ubyte[] data = [0xe0, 0x01, 0x00, 0xea, 0xe9, 0x81, 0x83, 0xd6, 0x87, 0xb4, 0x81, 0x61, 0x81, 0x62, 0xd6, 0x8a, 0x21, 0x01, 0x8b, 0x21, 0x02];
    assert(data.ion2json == `{"a":1,"b":2}`);
    // static assert(data.ion2json == `{"a":1,"b":2}`);
}

version(mir_ion_test) unittest
{
    assert("".json2ion.ion2text == "");
}

/++
Converts Ion Value Stream data to JSON text

The function performs `data.IonValueStream.serializeJsonPretty`.
+/
string ion2jsonPretty(scope const(ubyte)[] data)
    @safe pure
{
    pragma(inline, false);
    import mir.ser.json: serializeJsonPretty;
    return data.IonValueStream.serializeJsonPretty;
}

///
@safe pure
version(mir_ion_test) unittest
{
    static immutable ubyte[] data = [0xe0, 0x01, 0x00, 0xea, 0xe9, 0x81, 0x83, 0xd6, 0x87, 0xb4, 0x81, 0x61, 0x81, 0x62, 0xd6, 0x8a, 0x21, 0x01, 0x8b, 0x21, 0x02];
    assert(data.ion2jsonPretty == "{\n\t\"a\": 1,\n\t\"b\": 2\n}");
    // static assert(data.ion2jsonPretty == "{\n\t\"a\": 1,\n\t\"b\": 2\n}");
}

/++
Convert an Ion Text value to a Ion data.
Params:
    text = The text to convert
Returns:
    An array containing the Ion Text value as an Ion data.
+/
immutable(ubyte)[] text2ion(scope const(char)[] text)
    @trusted pure
{
    import mir.ion.internal.data_holder: ionPrefix;
    import mir.ion.symbol_table: IonSymbolTable;
    import mir.ion.internal.data_holder: ionPrefix;
    import mir.ser.ion : ionSerializer;
    import mir.serde : SerdeTarget;
    import mir.deser.text : IonTextDeserializer;
    enum nMax = 4096;

    IonSymbolTable!true table;
    auto serializer = ionSerializer!(nMax * 8, null, true);
    serializer.initialize(table);

    auto deser = IonTextDeserializer!(typeof(serializer))(&serializer);
    deser(text);
    serializer.finalize;

    if (table.initialized)
    {
        table.finalize;
        return cast(immutable) (ionPrefix ~ table.data ~ serializer.data);
    }
    else
    {
        return cast(immutable) (ionPrefix ~ serializer.data);
    }
}
///
@safe pure
version(mir_ion_test) unittest
{
    static immutable ubyte[] data = [0xe0, 0x01, 0x00, 0xea, 0xe9, 0x81, 0x83, 0xd6, 0x87, 0xb4, 0x81, 0x61, 0x81, 0x62, 0xd6, 0x8a, 0x21, 0x01, 0x8b, 0x21, 0x02];
    assert(`{"a":1,"b":2}`.text2ion == data);
    static assert(`{"a":1,"b":2}`.text2ion == data);
    enum s = `{a:2.232323e2, b:2.1,}`.text2ion;
}

/++
Converts Ion Text Value Stream to binary Ion data wrapped to $(SUBREF stream, IonValueStream).
+/
IonValueStream text2ionStream(scope const(char)[] text)
    @trusted pure
{
    return text.text2ion.IonValueStream;
}

///
@safe pure
version(mir_ion_test) unittest
{
    static immutable ubyte[] data = [0xe0, 0x01, 0x00, 0xea, 0xe9, 0x81, 0x83, 0xd6, 0x87, 0xb4, 0x81, 0x61, 0x81, 0x62, 0xd6, 0x8a, 0x21, 0x01, 0x8b, 0x21, 0x02];
    assert(`{a:1,b:2}`.text2ionStream.data == data);
}

/++
Convert an Ion Text value to a Ion Value Stream.

This function is the @nogc version of text2ion.
Params:
    text = The text to convert
    appender = A buffer that will receive the Ion binary data
+/
void text2ion(Appender)(scope const(char)[] text, scope ref Appender appender)
    @trusted
{
    import mir.ion.internal.data_holder: ionPrefix;
    import mir.ion.symbol_table: IonSymbolTable;
    import mir.ion.internal.data_holder: ionPrefix;
    import mir.ser.ion : ionSerializer;
    import mir.serde : SerdeTarget;
    import mir.deser.text : IonTextDeserializer;
    enum nMax = 4096;
    IonSymbolTable!false table = void;
    table.initialize;

    auto serializer = ionSerializer!(nMax * 8, null, false);
    serializer.initialize(table);

    auto deser = IonTextDeserializer!(typeof(serializer))(&serializer);

    deser(text);
    serializer.finalize;

    appender.put(ionPrefix);
    if (table.initialized)
    {
        table.finalize;
        appender.put(table.data);
    }
    appender.put(serializer.data);
}
///
@safe pure @nogc
version(mir_ion_test) unittest
{
    import mir.appender : scopedBuffer;
    static immutable data = [0xe0, 0x01, 0x00, 0xea, 0xe9, 0x81, 0x83, 0xd6, 0x87, 0xb4, 0x81, 0x61, 0x81, 0x62, 0xd6, 0x8a, 0x21, 0x01, 0x8b, 0x21, 0x02];
    auto buf = scopedBuffer!ubyte;
    text2ion("{\n\ta: 1,\n\tb: 2\n}", buf);
    assert(buf.data == data);
}

/++
Converts Ion Value Stream data to text.

The function performs `data.IonValueStream.serializeText`.
+/
string ion2text(scope const(ubyte)[] data)
    @safe pure
{
    pragma(inline, false);
    import mir.ser.text: serializeText;
    return data.IonValueStream.serializeText;
}

///
@safe pure
version(mir_ion_test) unittest
{
    static immutable ubyte[] data = [0xe0, 0x01, 0x00, 0xea, 0xe9, 0x81, 0x83, 0xd6, 0x87, 0xb4, 0x81, 0x61, 0x81, 0x62, 0xd6, 0x8a, 0x21, 0x01, 0x8b, 0x21, 0x02];
    assert(data.ion2text == `{a:1,b:2}`);
    // static assert(data.ion2text == `{a:1,b:2}`);
}

///
@safe pure
version(mir_ion_test) unittest
{
    static immutable ubyte[] data = [0xe0, 0x01, 0x00, 0xea, 0xea, 0x81, 0x83, 0xde, 0x86, 0x87, 0xb4, 0x83, 0x55, 0x53, 0x44, 0xe6, 0x81, 0x8a, 0x53, 0xc1, 0x04, 0xd2];
    assert(data.ion2text == `USD::123.4`);
    // static assert(data.ion2text == `USD::123.4`);
}

// 

/++
Converts Ion Value Stream data to text

The function performs `data.IonValueStream.serializeTextPretty`.
+/
string ion2textPretty(scope const(ubyte)[] data)
    @safe pure
{
    pragma(inline, false);
    import mir.ser.text: serializeTextPretty;
    return data.IonValueStream.serializeTextPretty;
}

///
@safe pure
version(mir_ion_test) unittest
{
    static immutable ubyte[] data = [0xe0, 0x01, 0x00, 0xea, 0xe9, 0x81, 0x83, 0xd6, 0x87, 0xb4, 0x81, 0x61, 0x81, 0x62, 0xd6, 0x8a, 0x21, 0x01, 0x8b, 0x21, 0x02];
    assert(data.ion2textPretty == "{\n\ta: 1,\n\tb: 2\n}");
    // static assert(data.ion2textPretty == "{\n\ta: 1,\n\tb: 2\n}");
}

void msgpack2ion(Appender)(scope const(ubyte)[] data, scope ref Appender appender)
    @trusted
{
    import mir.ion.internal.data_holder: ionPrefix;
    import mir.ion.symbol_table: IonSymbolTable;
    import mir.ion.internal.data_holder: ionPrefix;
    import mir.ser.ion : ionSerializer;
    import mir.serde : SerdeTarget;
    import mir.deser.msgpack : MsgpackValueStream;
    enum nMax = 4096;

    IonSymbolTable!false table = void;
    table.initialize;
    auto serializer = ionSerializer!(nMax * 8, null, false);
    serializer.initialize(table);

    data.MsgpackValueStream.serialize(serializer);
    serializer.finalize;

    appender.put(ionPrefix);
    if (table.initialized)
    {
        table.finalize;
        appender.put(table.data);
    }
    appender.put(serializer.data);
}

/++
Converts MessagePack binary data to Ion binary data.
+/
@safe pure
immutable(ubyte)[] msgpack2ion()(scope const(ubyte)[] data)
{
    import mir.appender : scopedBuffer;
    auto buf = scopedBuffer!ubyte;
    data.msgpack2ion(buf);
    return buf.data.idup;
}

@safe pure @nogc
version(mir_ion_test) unittest
{
    import mir.appender : scopedBuffer;
    import mir.deser.ion : deserializeIon;
    static struct S
    {
        bool compact;
        int schema;
    }

    auto buf = scopedBuffer!ubyte();
    static immutable ubyte[] data = [0x82, 0xa7, 0x63, 0x6f, 0x6d, 0x70, 0x61, 0x63, 0x74, 0xc3, 0xa6, 0x73, 0x63, 0x68, 0x65, 0x6d, 0x61, 0x04];
    data.msgpack2ion(buf);
    assert(buf.data.deserializeIon!S == S(true, 4));
}
  
@safe pure
version(mir_ion_test) unittest
{
    static immutable testStrings = [
        "2018-01-02T03:04:05Z",
        "2018-01-02T03:04:05.678901234Z",
        "2038-01-19T03:14:07.999999999Z",
        "2038-01-19T03:14:08Z",
        "2038-01-19T03:14:08.000000001Z",
        "2106-02-07T06:28:15Z",
        "2106-02-07T06:28:15.999999999Z",
        "2106-02-07T06:28:16.000000000Z",
        "2514-05-30T01:53:03.999999999Z",
        "2514-05-30T01:53:04.000000000Z",
        "1969-12-31T23:59:59.000000000Z",
        "1969-12-31T23:59:59.999999999Z",
        "1970-01-01T00:00:00Z",
        "1970-01-01T00:00:00.000000001Z",
        "1970-01-01T00:00:01Z",
        "1899-12-31T23:59:59.999999999Z",
        "1900-01-01T00:00:00.000000000Z",
        "9999-12-31T23:59:59.999999999Z",
    ];

    static immutable ubyte[][] testData = [
        [0xd6, 0xff, 0x5a, 0x4a, 0xf6, 0xa5],
        [0xd7, 0xff, 0xa1, 0xdc, 0xd7, 0xc8, 0x5a, 0x4a, 0xf6, 0xa5],
        [0xd7, 0xff, 0xee, 0x6b, 0x27, 0xfc, 0x7f, 0xff, 0xff, 0xff],
        [0xd6, 0xff, 0x80, 0x00, 0x00, 0x00],
        [0xd7, 0xff, 0x00, 0x00, 0x00, 0x04, 0x80, 0x00, 0x00, 0x00],
        [0xd6, 0xff, 0xff, 0xff, 0xff, 0xff],
        [0xd7, 0xff, 0xee, 0x6b, 0x27, 0xfc, 0xff, 0xff, 0xff, 0xff],
        [0xd7, 0xff, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
        [0xd7, 0xff, 0xee, 0x6b, 0x27, 0xff, 0xff, 0xff, 0xff, 0xff],
        [0xc7, 0x0c, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00],
        [0xc7, 0x0c, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
        [0xc7, 0x0c, 0xff, 0x3b, 0x9a, 0xc9, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
        [0xd6, 0xff, 0x00, 0x00, 0x00, 0x00],
        [0xd7, 0xff, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00],
        [0xd6, 0xff, 0x00, 0x00, 0x00, 0x01],
        [0xc7, 0x0c, 0xff, 0x3b, 0x9a, 0xc9, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7c, 0x55, 0x81, 0x7f],
        [0xc7, 0x0c, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x7c, 0x55, 0x81, 0x80],
        [0xc7, 0x0c, 0xff, 0x3b, 0x9a, 0xc9, 0xff, 0x00, 0x00, 0x00, 0x3a, 0xff, 0xf4, 0x41, 0x7f],
    ];

    foreach (i, ts; testStrings)
    {
        import mir.ser.ion : serializeIon;
        import mir.timestamp : Timestamp;
        auto mp = testData[i];
        auto ion = mp.msgpack2ion;
        import mir.test;
        ion.ion2text.should == ts;
        ts.Timestamp.serializeIon.ion2msgpack.should == mp;
    }
}

/++
Converts Ion binary data to MessagePack binary data.
+/
@safe pure
immutable(ubyte)[] ion2msgpack()(scope const(ubyte)[] data)
{
    import mir.ser.msgpack: serializeMsgpack;
    return data.IonValueStream.serializeMsgpack;
}

@safe pure
version(mir_ion_test) unittest
{
    import mir.test;
    foreach(text; [
        `null`,
        `true`,
        `1`,
        `-2`,
        `3.0`,
        `2001-01-02T03:04:05Z`,
        `[]`,
        `[1,-2,3.0]`,
        `[null,true,[1,-2,3.0],2001-01-02T03:04:05Z]`,
        `{}`,
        `{d:2001-01-02T03:04:05Z}`,
    ])
        text.text2ion.ion2msgpack.msgpack2ion.ion2text.should == text;
}
