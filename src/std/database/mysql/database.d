module std.database.mysql.database;
import std.conv;
import core.stdc.config;
import std.experimental.allocator.mallocator;
import std.datetime;

version(Windows) {
    pragma(lib, "libmysql");
}
else {
    pragma(lib, "mysqlclient");
}

import std.database.mysql.bindings;
import std.database.common;
import std.database.exception;
import std.database.resolver;
import std.database.allocator;
import std.database.impl;
import std.database.pool;
import std.container.array;
import std.experimental.logger;
import std.string;
import std.typecons;

// -----------------------------------------------
// template section for front end
// can't move into common file (impl.d) until forward bug is fixed

struct BasicDatabase(T,Impl) {
    alias Allocator = T.Allocator;
    //alias Pool = .Pool!(BasicDatabase,Connection!T); // no size error

    static const auto queryVariableType = QueryVariableType.QuestionMark;

    // temporary
    auto connection() {return Connection!T(this);}
    auto connection(string uri) {return Connection!T(this, uri);}
    void query(string sql) {connection().query(sql);}

    bool bindable() {return true;}

    private struct Payload {
        string defaultURI;
        Allocator allocator;

        this(string defaultURI_) {
            defaultURI = defaultURI_;
            allocator = Allocator();
        }
    }

    this(string defaultURI) {
        data_ = Data(defaultURI);
    }

    private alias RefCounted!(Impl, RefCountedAutoInitialize.no) Data;
    private Data data_;
}


struct BasicConnection(T,Impl) {
    alias Allocator = T.Allocator;
    //alias Database = .Database;
    //alias Statement = .Statement;

    auto statement(string sql) {return Statement!T(this,sql);}
    auto statement(X...) (string sql, X args) {return Statement!T(this,sql,args);}
    auto query(string sql) {return statement(sql).query();}
    auto query(T...) (string sql, T args) {return statement(sql).query(args);}

    private alias RefCounted!(Impl, RefCountedAutoInitialize.no) Data;
    private Data data_;

    package this(Database!T db, string uri="") {
        data_ = Data(db,uri);
    }

    package this(Database!T db, ref Allocator allocator, string uri="") {
        data_ = Data(db,uri);
    }


}

struct BasicStatement(T,Impl) {
    alias Allocator = T.Allocator;
    //alias Result = .Result;

    auto result() {return Result!T(this);}
    auto opSlice() {return result();} //fix

    this(Connection!T con, string sql) {
        data_ = Data(con,sql);
        prepare();
    }

    this(X...) (Connection!T con, string sql, X args) {
        data_ = Data(con,sql);
        prepare();
        bindAll(args);
    }

    string sql() {return data_.sql;}
    int binds() {return data_.binds;}

    void bind(int n, int value) {data_.bind(n, value);}
    void bind(int n, const char[] value){data_.bind(n,value);}

    auto query() {
        data_.query();
        return result();
    }

    auto query(X...) (X args) {
        bindAll(args);
        return query();
    }

    private:

    alias RefCounted!(Impl, RefCountedAutoInitialize.no) Data;
    Data data_;

    void bindAll(T...) (T args) {
        int col;
        foreach (arg; args) bind(++col, arg);
    }

    void prepare() {
        data_.prepare();
    }

    void reset() {} //SQLCloseCursor
}


struct BasicResult(T,Impl) {
    alias Allocator = T.Allocator;
    //alias Range = .ResultRange!T;
    //alias Row = .Row;

    int columns() {return data_.columns;}

    this(Statement!T stmt) {
        data_ = Data(stmt);
    }

    auto opSlice() {return ResultRange!T(this);}

package:
    bool start() {return data_.status == 0;}
    bool next() {return data_.next();}

    private:

    alias RefCounted!(Impl, RefCountedAutoInitialize.no) Data;
    Data data_;

}

struct BasicResultRange(T) {
    alias Result = .Result!T;
    alias Row = .Row!T;

    private Result result_;
    private bool ok_;

    this(Result result) {
        result_ = result;
        ok_ = result_.start();
    }

    bool empty() {return !ok_;}
    Row front() {return Row(&result_);}
    void popFront() {ok_ = result_.next();}
}

struct BasicRow(T) {
    alias Result = .Result!T;
    alias Value = .Value!T;

    this(Result* result) {
        result_ = result;
    }

    int columns() {return result_.columns();}
    Value opIndex(size_t idx) {return Value(&result_.data_.bind[idx]);}

    private Result* result_;
}

struct BasicValue(T,Impl) {
    alias Bind = .Bind!T;
    private Bind* bind_;
    alias Converter = .Converter!Impl;

    this(Bind* bind) {bind_ = bind;}

    auto as(T:int)() {return Converter.convert!T(bind_);}
    auto as(T:string)() {return Converter.convert!T(bind_);}
    auto as(T:Date)() {return Converter.convert!T(bind_);}

    /*
    //inout(char)[]
    char[] chars() {
        Impl.checkType!string(bind_);
        return Impl.get!(char[])(bind_); 
    }
    */

    auto chars() {return as!string();}
}

struct EfficientValue(T,Impl) {
    alias Bind = .Bind!T;
    private Bind* bind_;
    alias Converter = .Converter!Impl;

    this(Bind* bind) {bind_ = bind;}

    auto as(T:int)() {return Converter.convertDirect!T(bind_);}
    auto as(T:string)() {return Converter.convertDirect!T(bind_);}
    auto as(T:Date)() {return Converter.convertDirect!T(bind_);}
}

// -----------------------------------------------
// target database specfic code

// alias Database(T) = std.database.impl.Database!(T,DatabaseImpl!T); // blocked by DMD bug

alias Database(T) = BasicDatabase!(T,DatabaseImpl!T);
alias Connection(T) = BasicConnection!(T,ConnectionImpl!T);
alias Statement(T) = BasicStatement!(T,StatementImpl!T);
alias Result(T) = BasicResult!(T,ResultImpl!T);
alias ResultRange(T) = BasicResultRange!(T);
alias Row(T) = BasicRow!(T);
alias Value(T) = BasicValue!(T,ResultImpl!T);
//alias Value(T) = EfficientValue!(T,ResultImpl!T);

struct DefaultPolicy {
    alias Allocator = MyMallocator;
}

auto createDatabase()(string defaultURI="") {
    return Database!DefaultPolicy(defaultURI);  
}

auto createDatabase(T)(string defaultURI="") {
    return Database!T(defaultURI);  
}

struct DatabaseImpl(T) {
    alias Allocator = T.Allocator;
    string defaultURI;
    Allocator allocator;

    this(string defaultURI_) {
        defaultURI = defaultURI_;
        allocator = Allocator();
    }
}


struct ConnectionImpl(T) {
    Database!T db;
    string uri;
    MYSQL *mysql;

    this(Database!T db_, string uri_) {
        db = db_;
        uri = uri_.length == 0 ? db_.data_.defaultURI : uri_;

        mysql = mysql_init(null);
        if (!mysql) {
            throw new DatabaseException("couldn't init mysql");
        }

        open();
    }

    ~this() {
        info("mysql closing ", uri);
        if (mysql) {
            mysql_close(mysql);
            mysql = null;
        }
    }

    this(this) { assert(false); }
    void opAssign(ConnectionImpl rhs) { assert(false); }

    void open() {
        alias const(ubyte)* cstring;

        Source source = resolve(uri);

        if (!mysql_real_connect(
                    mysql,
                    cast(cstring) toStringz(source.server),
                    cast(cstring) toStringz(source.username),
                    cast(cstring) toStringz(source.password),
                    cast(cstring) toStringz(source.database),
                    0,
                    null,
                    0)) {
            throw new ConnectionException("couldn't connect");
        }
    }
}

struct Describe(T) {
    int index;
    immutable(char)[] name;
    MYSQL_FIELD *field;
}

struct Bind(T) {
    ValueType type;
    int mysql_type;
    int allocSize;
    void[] data;
    c_ulong length;
    my_bool is_null;
    my_bool error;
}

void bindSetup(T)(ref Array!(Bind!T) bind, ref Array!MYSQL_BIND mysqlBind) {
    // make this efficient
    mysqlBind.clear();
    mysqlBind.reserve(bind.length);
    for(int i=0; i!=bind.length; ++i) {
        mysqlBind ~= MYSQL_BIND();
        //import core.stdc.string: memset;
        //memset(mb, 0, MYSQL_BIND.sizeof); // might not be needed: D struct
        auto b = &bind[i];
        auto mb = &mysqlBind[i];
        mb.buffer_type = b.mysql_type;
        mb.buffer = b.data.ptr;
        mb.buffer_length = b.allocSize;
        mb.length = &b.length;
        mb.is_null = &b.is_null;
        mb.error = &b.error;
    }
}


struct StatementImpl(T) {
    alias Allocator = T.Allocator;
    alias Bind = .Bind!T;

    Connection!T con;
    string sql;
    Allocator *allocator;
    MYSQL_STMT *stmt;
    bool hasRows;
    uint binds;
    Array!Bind inputBind;
    Array!MYSQL_BIND mysqlBind;
    bool bindInit;

    this(Connection!T con_, string sql_) {
        con = con_;
        sql = sql_;
        allocator = &con.data_.db.data_.allocator;

        stmt = mysql_stmt_init(con.data_.mysql);
        if (!stmt) throw new DatabaseException("stmt error");
    }

    ~this() {
        foreach(b; inputBind) allocator.deallocate(b.data);
        if (stmt) mysql_stmt_close(stmt);
        // stmt = null? needed
    }

    // hoist?
    this(this) { assert(false); }
    void opAssign(StatementImpl rhs) { assert(false); }


    void prepare() {
        check("mysql_stmt_prepare", stmt, mysql_stmt_prepare(
                    stmt,
                    cast(char*) sql.ptr,
                    sql.length));

        binds = cast(uint) mysql_stmt_param_count(stmt);
    }

    void query() {

        if (inputBind.length && !bindInit) {
            bindInit = true;

            bindSetup(inputBind, mysqlBind);

            check("mysql_stmt_bind_param",
                    stmt,
                    mysql_stmt_bind_param(stmt, &mysqlBind[0]));
        }

        info("execute: ", sql);
        check("mysql_stmt_execute", stmt, mysql_stmt_execute(stmt));
    }

    void bind(int n, int value) {
        info("input bind: n: ", n, ", value: ", value);
        auto b = bindAlloc(n, MYSQL_TYPE_LONG, int.sizeof);
        b.is_null = 0;
        b.error = 0;
        *cast(int*)(b.data.ptr) = value;

    }

    void bind(int n, const char[] value){
        import core.stdc.string: strncpy;
        info("input bind: n: ", n, ", value: ", value);

        auto b = bindAlloc(n, MYSQL_TYPE_STRING, 100+1); // fix
        b.is_null = 0;
        b.error = 0;

        auto p = cast(char*) b.data.ptr;
        strncpy(p, value.ptr, value.length);
        p[value.length] = 0;
        b.length = value.length;
    }

    Bind* bindAlloc(int n, int mysql_type, int allocSize) {
        if (n==0) throw new DatabaseException("zero index");
        auto idx = n-1;
        if (idx > inputBind.length) throw new DatabaseException("bind range error");
        if (idx == inputBind.length) inputBind ~= Bind();
        auto b = &inputBind[idx];
        if (allocSize <= b.data.length) return b; // fix
        b.mysql_type = mysql_type;
        b.allocSize = allocSize;
        b.data = allocator.allocate(b.allocSize);
        return b;
    }

    static void check(string msg, MYSQL_STMT* stmt, int ret) {
        info(msg, ":", ret);
        if (ret) error(msg,stmt,ret);
    }

    static void error(string msg, MYSQL_STMT* stmt, int ret) {
        info(msg, ":", ret);
        if (!ret) return;
        import core.stdc.string: strlen;
        const(char*) err = mysql_stmt_error(stmt);
        info("error: ", err[0..strlen(err)]); //fix
        throw new DatabaseException("mysql error: " ~ msg);
    }
}

struct ResultImpl(T) {
    this(this) { assert(false); }
    void opAssign(ResultImpl rhs) { assert(false); }

    alias Allocator = T.Allocator;
    alias Describe = .Describe!T;
    alias Bind = .Bind!T;
    Statement!T stmt;
    Allocator *allocator;
    uint columns;
    Array!Describe describe;
    Array!Bind bind;
    Array!MYSQL_BIND mysqlBind;
    MYSQL_RES *result_metadata;
    int status;

    static const maxData = 256;

    this(Statement!T stmt_) {
        stmt = stmt_;
        allocator = stmt.data_.allocator;

        result_metadata = mysql_stmt_result_metadata(stmt.data_.stmt);
        if (!result_metadata) return;
        //columns = mysql_num_fields(result_metadata);

        build_describe();
        build_bind();
        next();
    }

    ~this() {
        foreach(b; bind) allocator.deallocate(b.data);
        if (result_metadata) mysql_free_result(result_metadata);
    }

    void build_describe() {
        import core.stdc.string: strlen;

        columns = cast(uint) mysql_stmt_field_count(stmt.data_.stmt);

        describe.reserve(columns);

        for(int i = 0; i < columns; ++i) {
            describe ~= Describe();
            auto d = &describe.back();

            d.index = i;
            d.field = mysql_fetch_field(result_metadata);

            auto p = cast(immutable(char)*) d.field.name;
            d.name = p[0 .. strlen(p)];

            info("describe: name: ", d.name, ", mysql type: ", d.field.type);
        }
    }

    void build_bind() {
        import core.stdc.string: memset;
        import core.memory : GC;

        bind.reserve(columns);

        for(int i = 0; i < columns; ++i) {
            auto d = &describe[i];
            bind ~= Bind();
            auto b = &bind.back();

            // let in ints for now
            if (d.field.type == MYSQL_TYPE_LONG) {
                b.mysql_type = d.field.type;
                b.type = ValueType.Int;
            } else {
                b.mysql_type = MYSQL_TYPE_STRING;
                b.type = ValueType.String;
            }

            b.allocSize = cast(uint)(d.field.length + 1);
            b.data = allocator.allocate(b.allocSize);
        }

        bindSetup(bind, mysqlBind);

        mysql_stmt_bind_result(stmt.data_.stmt, &mysqlBind.front());
    }

    bool next() {
        status = mysql_stmt_fetch(stmt.data_.stmt);
        if (!status) {
            return true;
        } else if (status == MYSQL_NO_DATA) {
            //rows_ = row_count_;
            return false;
        } else if (status == MYSQL_DATA_TRUNCATED) {
            throw new DatabaseException("fetch: database truncation");
        }

        stmt.error("mysql_stmt_fetch",stmt.data_.stmt,status);
        return false;
    }

    // value getters

    static char[] get(X:char[])(Bind *b) {
        auto ptr = cast(char*) b.data.ptr;
        return ptr[0..b.length];
    }

    static auto get(X:string)(Bind *b) {
        return cast(string) get!(char[])(b);
    }

    static auto get(X:int)(Bind *b) {
        return *cast(int*) b.data.ptr;
    }

    static auto get(X:Date)(Bind *b) {
        return Date(2016,1,1); // fix
    }

    static void checkType(T)(Bind *b) {
        int x = TypeInfo!T.type();
        int y = b.mysql_type;
        if (x == y) return;
        warning("type pair mismatch: ",x, ":", y);
        throw new DatabaseException("type mismatch");
    }

    // refactor as a better 1-n bind mapping
    struct TypeInfo(T:int) {static int type() {return MYSQL_TYPE_LONG;}}
    struct TypeInfo(T:string) {static int type() {return MYSQL_TYPE_STRING;}}
    struct TypeInfo(T:Date) {static int type() {return MYSQL_TYPE_DATE;}}

}

