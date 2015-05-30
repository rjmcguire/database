module std.database.sqlite.connection;
pragma(lib, "sqlite3");

import std.string;
import std.typecons;
import std.c.stdlib;

public import std.database.exception;
public import std.database.sqlite.database;
public import std.database.sqlite.bindings;

import std.stdio;

struct Connection {
    alias Statement = .Statement;

    private struct Payload {
        Database* db;
        string filename;
        sqlite3* sq;

        this(Database* db_, string filename_) {
            db = db_;
            filename = filename_;
            writeln("sqlite opening ", filename);
            int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
            int rc = sqlite3_open_v2(toStringz(filename), &sq, flags, null);
            if (rc) {
                writeln("error: rc: ", rc, sqlite3_errmsg(sq));
            }
        }

        ~this() {
            writeln("sqlite closing ", filename);
            if (sq) {
                int rc = sqlite3_close(sq);
                sq = null;
            }
        }

        this(this) { assert(false); }
        void opAssign(Connection.Payload rhs) { assert(false); }
    }

    private alias RefCounted!(Payload, RefCountedAutoInitialize.no) Data;
    private Data data_;

    package this(Database db, string url) {
        data_ = Data(&db,url);
    }

    Statement statement(string sql) {
        return Statement(this, sql);
    }

    // statements with bind (variadic coming)
    Statement statement(string sql, int v1) {
        return Statement(this, sql, v1);
    }
}

struct Statement {

    alias Result = .Result;
    alias Range = .ResultRange;

    this(Connection con, string sql) {
        data_ = Data(con,sql);
        prepare();
        // must be able to detect binds in all DBs
        if (!data_.binds) execute();
    }

    this(Connection con, string sql, int v1) {
        data_ = Data(con,sql);
        prepare();
        bind(1, v1);
        execute();
    }

    string sql() {return data_.sql;}
    int columns() {return data_.columns;}

    void bind(int col, int value){
        int rc = sqlite3_bind_int(
                data_.st, 
                col,
                value);
        if (rc != SQLITE_OK) {
            throw_error("sqlite3_bind_int");
        }
    }

    void bind(int col, const char[] value){
        if(value is null) {
            int rc = sqlite3_bind_null(data_.st, col);
            if (rc != SQLITE_OK) throw_error("bind1");
        } else {
            //cast(void*)-1);
            int rc = sqlite3_bind_text(
                    data_.st, 
                    col,
                    value.ptr,
                    cast(int) value.length,
                    null);
            if (rc != SQLITE_OK) {
                writeln(rc);
                throw_error("bind2");
            }
        }
    }


    void execute() {
        int status = sqlite3_step(data_.st);
        if (status == SQLITE_ROW) {
            data_.hasRows = true;
        } else if (status == SQLITE_DONE) {
            reset();
        } else throw new DatabaseException("step error");
    }

    // temporary: reimplement with variadics
    void execute(const char[] v1, int v2) {
        bind(1,v1);
        bind(2,v2);
        execute();
    }

    ResultRange range() {
        return ResultRange(Result(this));
    }

    bool hasRows() {
        return data_.hasRows;
    }

    private:

    struct Payload {
        Connection con;
        string sql;
        sqlite3* sq;
        sqlite3_stmt *st;
        bool hasRows;
        int columns;
        int binds;

        this(Connection con_, string sql_) {
            con = con_;
            sql = sql_;
            sq = con.data_.sq;
        }

        ~this() {
            //writeln("sqlite statement closing ", filename_);
            if (st) {
                int res = sqlite3_finalize(st);
                st = null;
            }
        }

        this(this) { assert(false); }
        void opAssign(Statement.Payload rhs) { assert(false); }
    }

    private alias RefCounted!(Payload, RefCountedAutoInitialize.no) Data;
    private Data data_;


    void prepare() {
        if (!data_.st) { 
            int res = sqlite3_prepare_v2(
                    data_.sq, 
                    toStringz(data_.sql), 
                    cast(int) data_.sql.length + 1, 
                    &data_.st, 
                    null);
            if (res != SQLITE_OK) throw new DatabaseException("prepare error: " ~ data_.sql);

            data_.columns = sqlite3_column_count(data_.st);
            data_.binds = sqlite3_bind_parameter_count(data_.st);
        }
    }

    void reset() {
        int status = sqlite3_reset(data_.st);
        if (status != SQLITE_OK) throw new DatabaseException("sqlite3_reset error");
    }

}


struct Result {
    alias Row = .Row;

    private struct Payload {
        private Statement stmt_;
        private sqlite3_stmt *st_;
        int status_;

        this(Statement stmt) {
            stmt_ = stmt;
            st_ = stmt_.data_.st;
        }

        //~this() {}

        this(this) { assert(false); }
        void opAssign(Statement.Payload rhs) { assert(false); }

        bool next() {
            status_ = sqlite3_step(st_);
            if (status_ == SQLITE_ROW) return true;
            if (status_ == SQLITE_DONE) {
                stmt_.reset();
                return false;
            }
            //throw new DatabaseException("sqlite3_step error: status: " ~ to!string(status_));
            throw new DatabaseException("sqlite3_step error: status: ");
        }

    }

    private alias RefCounted!(Payload, RefCountedAutoInitialize.no) Data;
    private Data data_;

    int columns() {return data_.stmt_.columns();}

    this(Statement stmt) {
        data_ = Data(stmt);
    }

    ResultRange range() {return ResultRange(this);}

    public bool start() {return data_.stmt_.hasRows();}
    public bool next() {return data_.next();}

}


struct Value {
    private Result* result_;
    private ulong idx_;

    public this(Result* result, ulong idx) {
        result_ = result;
        idx_ = idx;
    }

    int get(T) () {
        return toInt();
    }

    // bounds check or covered?
    int toInt() {
        return sqlite3_column_int((*result_).data_.st_, cast(int) idx_);
    }

    // not efficient
    string toString() {
        import std.conv;
        return to!string(sqlite3_column_text((*result_).data_.st_, cast(int) idx_));
    }

    // char*, string_ref?

    const(char*) toStringz() {
        // this may not work either because it's not around for the whole row
        return sqlite3_column_text((*result_).data_.st_, cast(int) idx_);
    }
}

struct Row {
    alias Value = .Value;

    private Result* result_;

    this(Result* result) {
        result_ = result;
    }

    int columns() {return result_.columns();}

    Value opIndex(size_t idx) {
        return Value(result_, idx);
    }
}

struct ResultRange {
    // implements a One Pass Range
    alias Row = .Row;

    private Result result_;
    private bool ok_;

    this(Result result) {
        result_ = result;
        ok_ = result_.start();
    }

    bool empty() {
        return !ok_;
    }

    Row front() {
        return Row(&result_);
    }

    void popFront() {
        ok_ = result_.next();
    }
}

void throw_error(string label) {
    throw new DatabaseException(label);
}

void throw_error(string label, char *msg) {
    // frees up pass char * as required by sqlite
    import core.stdc.string : strlen;
    char[] m;
    sizediff_t sz = strlen(msg);
    m.length = sz;
    for(int i = 0; i != sz; i++) m[i] = msg[i];
    sqlite3_free(msg);
    throw new DatabaseException(label ~ m.idup);
}

extern(C) int sqlite_callback(void* cb, int howmany, char** text, char** columns) {
    return 0;
}
