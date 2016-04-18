module std.database.mysql.database;
import std.conv;
import core.stdc.config;
import std.datetime;

import std.stdio;
import std.database.common;

version(Windows) {
    pragma(lib, "libmysql");
}
else {
    pragma(lib, "mysqlclient");
}

import std.database.mysql.bindings;
import std.database.exception;
import std.database.resolver;
import std.database.allocator;
import std.database.impl;
import std.container.array;
import std.experimental.logger;
import std.string;

// -----------------------------------------------
// template section for front end
// can't move into common file (impl.d) until forward bug is fixed

// -----------------------------------------------
// target database specfic code

// alias Database(T) = std.database.impl.Database!(T,DatabaseImpl!T); // blocked by DMD bug

alias Database(T) = BasicDatabase!(DatabaseImpl!T);
alias Connection(T) = BasicConnection!(ConnectionImpl!T);
alias Statement(T) = BasicStatement!(StatementImpl!T);
alias Result(T) = BasicResult!(ResultImpl!T);
alias ResultRange(T) = BasicResultRange!(Result!T);
alias Row(T) = BasicRow!(ResultImpl!T);
alias Value(T) = BasicValue!(ResultImpl!T);
//alias Value(T) = EfficientValue!(ResultImpl!T);

struct DefaultPolicy {
    alias Allocator = MyMallocator;
}

struct Impl {
    alias Database(T) = .DatabaseImpl!T;
    alias Connection(T) = .ConnectionImpl!T;
    alias Statement(T) = .StatementImpl!T;
    alias Result(T) = .ResultImpl!T;
}

auto createDatabase()(string defaultURI="") {
    return Database!DefaultPolicy(defaultURI);  
}

auto createDatabase(T)(string defaultURI="") {
    return Database!T(defaultURI);  
}

struct DatabaseImpl(T) {
    alias Allocator = T.Allocator;
    alias Connection = .ConnectionImpl!T;
    alias queryVariableType = QueryVariableType.QuestionMark;

    string defaultURI;
    Allocator allocator;

    this(string defaultURI_) {
        defaultURI = defaultURI_;
        allocator = Allocator();
    }

    bool bindable() {return true;}
    bool dateBinding() {return true;}
    bool poolEnable() {return false;}

    //~this() {log("~Database");}
}

struct ConnectionImpl(T) {
    alias Allocator = T.Allocator;
    alias Database = .DatabaseImpl!T;
    alias Statement = .StatementImpl!T;

    DatabaseImpl!T *db;
    string uri;
    MYSQL *mysql;

    this(DatabaseImpl!T *db_, string uri_) {
        db = db_;
        uri = uri_.length == 0 ? db_.defaultURI : uri_;

        mysql = mysql_init(null);
        if (!mysql) {
            throw new DatabaseException("couldn't init mysql");
        }

        open();
    }

    ~this() {
        //log("~Statement");
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
    alias Connection = .ConnectionImpl!T;
    alias Bind = .Bind!T;
    alias Result = .ResultImpl!T;
    alias Allocator = T.Allocator;

    ConnectionImpl!T *con;
    string sql;
    Allocator *allocator;
    MYSQL_STMT *stmt;
    bool hasRows;
    uint binds;
    Array!Bind inputBind;
    Array!MYSQL_BIND mysqlBind;
    bool bindInit;

    this(ConnectionImpl!T *con_, string sql_) {
        con = con_;
        sql = sql_;
        allocator = &con.db.allocator;

        stmt = mysql_stmt_init(con.mysql);
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

    void query(X...) (X args) {
        bindAll(args);
        query();
    }

    void reset() {
    }

    private void bindAll(T...) (T args) {
        int col;
        foreach (arg; args) bind(++col, arg);
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

    void bind(int n, Date d) {
        auto b = bindAlloc(n, MYSQL_TYPE_DATE, MYSQL_TIME.sizeof);
        b.is_null = 0;
        b.error = 0;

        auto p = cast(MYSQL_TIME*) b.data.ptr;
        p.year = d.year;
        p.month = d.month;
        p.day = d.day;
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
        if (ret) createError(msg,stmt,ret);
    }

    static void createError(string msg, MYSQL_STMT* stmt, int ret) {
        info(msg, ":", ret);
        if (!ret) return;
        import core.stdc.string: strlen;
        const(char*) err = mysql_stmt_error(stmt);
        //info("error: ", err[0..strlen(err)]); //fix
        throw new DatabaseException("mysql error: " ~ msg);
    }
}

struct ResultImpl(T) {
    alias Statement = .StatementImpl!T;
    alias Bind = .Bind!T;

    this(this) { assert(false); }
    void opAssign(ResultImpl rhs) { assert(false); }

    alias Allocator = T.Allocator;
    alias Describe = .Describe!T;
    Statement *stmt;
    Allocator *allocator;
    uint columns;
    Array!Describe describe;
    Array!Bind bind;
    Array!MYSQL_BIND mysqlBind;
    MYSQL_RES *result_metadata;
    int status;

    static const maxData = 256;

    this(Statement* stmt_) {
        stmt = stmt_;
        allocator = stmt.allocator;

        result_metadata = mysql_stmt_result_metadata(stmt.stmt);
        if (!result_metadata) return;
        //columns = mysql_num_fields(result_metadata);

        build_describe();
        build_bind();
        next();
    }

    ~this() {
        //log("~Result");
        foreach(b; bind) allocator.deallocate(b.data);
        if (result_metadata) mysql_free_result(result_metadata);
    }

    void build_describe() {
        import core.stdc.string: strlen;

        columns = cast(uint) mysql_stmt_field_count(stmt.stmt);

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
            } else if (d.field.type == MYSQL_TYPE_DATE) {
                b.mysql_type = d.field.type;
                b.type = ValueType.Date;
            } else {
                b.mysql_type = MYSQL_TYPE_STRING;
                b.type = ValueType.String;
            }

            b.allocSize = cast(uint)(d.field.length + 1);
            b.data = allocator.allocate(b.allocSize);
        }

        bindSetup(bind, mysqlBind);

        mysql_stmt_bind_result(stmt.stmt, &mysqlBind.front());
    }

    bool start() {return status == 0;}

    bool next() {
        status = mysql_stmt_fetch(stmt.stmt);
        if (!status) {
            return true;
        } else if (status == MYSQL_NO_DATA) {
            //rows_ = row_count_;
            return false;
        } else if (status == MYSQL_DATA_TRUNCATED) {
            throw new DatabaseException("fetch: database truncation");
        }

        StatementImpl!T.createError("mysql_stmt_fetch",stmt.stmt,status);
        return false;
    }

    // value getters

    char[] get(X:char[])(Bind *b) {
        auto ptr = cast(char*) b.data.ptr;
        return ptr[0..b.length];
    }

    auto get(X:string)(Bind *b) {
        return cast(string) get!(char[])(b);
    }

    auto get(X:int)(Bind *b) {
        return *cast(int*) b.data.ptr;
    }

    auto get(X:Date)(Bind *b) {
        //return Date(2016,1,1); // fix
        MYSQL_TIME *t = cast(MYSQL_TIME*) b.data.ptr;
        //t.year,t.month,t.day,t.hour,t.minute,t.second
        return Date(t.year,t.month,t.day);
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

