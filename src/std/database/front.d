module std.database.front;
import std.experimental.logger;
import std.database.exception;
import std.datetime;

import std.typecons;
import std.database.common;
import std.database.pool;
import std.database.resolver;
import std.database.source;

import std.database.allocator;
import std.traits;

/*
   require a specific minimum version of DMD (2.071)
   can't use yet because DMD is reporting wrong version

   import std.compiler;
   static assert(
   name != "Digital Mars D" ||
   (version_major == 2 && version_minor == 70));
 */


enum ValueType {
    Int,
    String,
    Date,
}

enum Feature {
    InputBinding,
    DateBinding,
    ConnectionPool,
    OutputArrayBinding,
}

alias FeatureArray = Feature[];

struct BasicDatabase(D,P) {
    alias Driver = D;
    alias Policy = P;
    alias Database = Driver.Database;
    alias Allocator = Policy.Allocator;
    alias Connection = BasicConnection!(Driver,Policy);
    alias Cell = BasicCell!(Driver,Policy);
    alias Pool = .Pool!(Driver.Connection);
    alias ScopedResource = .ScopedResource!Pool;

    alias queryVariableType = Database.queryVariableType;

    auto connection() {return Connection(this);}
    auto connection(string uri) {return Connection(this, uri);}

    auto statement(string sql) {return connection().statement(sql);}
    auto statement(X...) (string sql, X args) {return connection.statement(sql,args);}

    auto query(string sql) {return connection().query(sql);}
    auto query(T...) (string sql, T args) {return statement(sql).query(args);}

    static bool hasFeature(Feature feature) {
        import std.algorithm;
        import std.range.primitives: empty;
        auto r = find(Database.features, feature);
        return !r.empty;
    }

    auto ref driverDatabase() {return data_.database;}

    private struct Payload {
        string defaultURI;
        Database database;
        Pool pool;
        bool poolEnable = hasFeature(Feature.ConnectionPool);
        this(string defaultURI_) {
            defaultURI = defaultURI_;
            database = Database(defaultURI_);
            pool = Pool(poolEnable);
        }
    }

    this(string defaultURI) {
        data_ = Data(defaultURI);
    }

    private alias RefCounted!(Payload, RefCountedAutoInitialize.no) Data;

    private Data data_;
}


struct BasicConnection(D,P) {
    alias Driver = D;
    alias Policy = P;
    alias DriverConnection = Driver.Connection;
    alias Statement = BasicStatement!(Driver,Policy);
    alias Database = BasicDatabase!(Driver,Policy);
    alias Pool = Database.Pool;
    alias ScopedResource = Database.ScopedResource;
    alias DatabaseImpl = Driver.Database;

    auto statement(string sql) {return Statement(this,sql);}
    auto statement(X...) (string sql, X args) {return Statement(this,sql,args);}
    auto query(string sql) {return statement(sql).query();}
    auto query(T...) (string sql, T args) {return statement(sql).query(args);}

    auto rowArraySize(int rows) {
        rowArraySize_ = rows;
        return this;
    }

    private alias RefCounted!(ScopedResource, RefCountedAutoInitialize.no) Data;

    //private Database db_; // problem (fix in 2.072)
    private Data data_;
    private Pool* pool_;
    string uri_;
    int rowArraySize_ = 1;

    package this(Database db) {this(db,"");}

    package this(Database db, string uri) {
        //db_ = db;
        uri_ = uri.length != 0 ? uri : db.data_.defaultURI;
        pool_ = &db.data_.pool;
        Source source = resolve(uri_);
        data_ = Data(*pool_, pool_.acquire(&db.driverDatabase(), source));
    }

    private auto ref driverConnection() {
        return data_.resource.resource;
    }

    static if (hasMember!(Database, "socket")) {
        auto socket() {return driverConnection.socket;}
    }

    // handle()
    // be carful about Connection going out of scope or being destructed
    // while a handle is in use  (Use a connection variable to extend scope)

    static if (hasMember!(Database, "handle")) {
        auto handle() {return driverConnection.handle;}
    }

    /*
       this(Database db, ref Allocator allocator, string uri="") {
//db_ = db;
data_ = Data(&db.data_.refCountedPayload(),uri);
}
     */


}

struct BasicStatement(D,P) {
    alias Driver = D;
    alias Policy = P;
    alias DriverStatement = Driver.Statement;
    alias Connection = BasicConnection!(Driver,Policy);
    alias Result = BasicResult!(Driver,Policy);
    //alias Allocator = Policy.Allocator;
    alias ScopedResource = Connection.ScopedResource;

    auto result() {
        if (state != State.Executed) throw new DatabaseException("statement not executed");
        return Result(this);
    }
    auto opSlice() {return result();} //fix

    enum State {
        Undef,
        Prepared,
        Executed,
    }


    this(Connection con, string sql) {
        con_ = con;
        data_ = Data(con_.driverConnection,sql);
        rowArraySize_ = con.rowArraySize_;
        prepare();
    }

    /*
    // determine if needed and how to do
    this(X...) (Connection con, string sql, X args) {
    con_ = con;
    data_ = Data(&con.data_.refCountedPayload(),sql);
    prepare();
    bindAll(args);
    }
     */

    string sql() {return data_.sql;}
    int binds() {return data_.binds;}

    void bind(int n, int value) {data_.bind(n, value);}
    void bind(int n, const char[] value){data_.bind(n,value);}

    auto query() {
        data_.query();
        state = State.Executed;
        return Result(this, rowArraySize_);
    }

    auto query(X...) (X args) {
        data_.query(args);
        state = State.Executed;
        return Result(this, rowArraySize_);
    }

    // experimental async
    /*
       static if (hasMember!(Statement, "asyncQuery")) {
       auto asyncQuery() {
       data_.asyncQuery();
       return Result(this);
       }
       }
     */


    private:
    alias RefCounted!(DriverStatement, RefCountedAutoInitialize.no) Data;

    Data data_;
    Connection con_;
    State state;
    int rowArraySize_;

    void prepare() {
        data_.prepare();
        state = State.Prepared;
    }

    void reset() {data_.reset();} //SQLCloseCursor
}


struct BasicResult(D,P) {
    alias Driver = D;
    alias Policy = P;
    alias ResultImpl = Driver.Result;
    alias Statement = BasicStatement!(Driver,Policy);
    alias ResultRange = BasicResultRange!(Driver,Policy);
    //alias Allocator = Driver.Policy.Allocator;
    alias Bind = Driver.Bind;
    //alias Row = .Row;

    int columns() {return data_.columns;}

    this(Statement stmt, int rowArraySize = 1) {
        stmt_ = stmt;
        rowArraySize_ = rowArraySize;
        data_ = Data(&stmt.data_.refCountedPayload(), rowArraySize_);
        if (!data_.hasResult()) return;
        rowsFetched_ = data_.fetch();
    }

    auto opSlice() {return ResultRange(this);}

package:
    int rowsFetched() {return rowsFetched_;}

    bool next() {
        if (++rowIdx_ == rowsFetched_) {
            rowsFetched_ = data_.fetch();
            if (!rowsFetched_) return false;
            rowIdx_ = 0;
        }
        return true;
    }

    auto ref result() {return data_.refCountedPayload();}

    private:
    Statement stmt_;
    int rowArraySize_; //maybe move into RC
    int rowIdx_;
    int rowsFetched_;

    alias RefCounted!(ResultImpl, RefCountedAutoInitialize.no) Data;
    Data data_;
}

struct BasicResultRange(D,P) {
    alias Driver = D;
    alias Policy = P;
    alias Result = BasicResult!(Driver,Policy);
    alias Row = BasicRow!(Driver,Policy);

    private Result result_;
    private bool ok_;

    this(Result result) {
        result_ = result;
        ok_ = result.rowsFetched != 0;
    }

    bool empty() {return !ok_;}
    Row front() {return Row(&result_);}
    void popFront() {ok_ = result_.next();}
}

struct BasicRow(D,P) {
    alias Driver = D;
    alias Policy = P;
    alias Result = BasicResult!(Driver,Policy);
    alias Cell = BasicCell!(Driver,Policy);
    alias Value = BasicValue!(Driver,Policy);

    this(Result* result) {
        result_ = result;
    }

    int columns() {return result_.columns();}

    Value opIndex(size_t idx) {
        // needs work
        auto cell = Cell(result_, &result_.data_.bind[idx]);
        return Value(
                result_,
                cell);
                //&result_.data_.bind[idx]);
    }

    private Result* result_;
}


struct BasicValue(D,P) {
    alias Driver = D;
    alias Policy = P;
    //alias Result = Driver.Result;
    alias Result = BasicResult!(Driver,Policy);
    alias Cell = BasicCell!(Driver,Policy);
    alias Bind = Driver.Bind;
    private Result* result_;
    private Bind* bind_;
    private Cell cell_;
    alias Converter = .Converter!(Driver,Policy);

    this(Result* result, Cell cell) {
        result_ = result;
        //bind_ = bind;
        cell_ = cell;
    }

    private auto resultPtr() {
        return &result_.result();
    }

    auto as(T:int)() {return Converter.convert!T(resultPtr, cell_);}
    auto as(T:string)() {return Converter.convert!T(resultPtr, cell_);}
    auto as(T:Date)() {return Converter.convert!T(resultPtr, cell_);}

    /*
    //inout(char)[]
    char[] chars() {
    Impl.checkType!string(bind_);
    return Impl.get!(char[])(bind_); 
    }
     */

    auto chars() {return as!string();}
}


// extra stuff


struct EfficientValue(T) {
    alias Driver = T.Driver;
    alias Bind = Driver.Bind;
    private Bind* bind_;
    alias Converter = .Converter!Driver;

    this(Bind* bind) {bind_ = bind;}

    auto as(T:int)() {return Converter.convertDirect!T(bind_);}
    auto as(T:string)() {return Converter.convertDirect!T(bind_);}
    auto as(T:Date)() {return Converter.convertDirect!T(bind_);}
}


// improve
struct TypeInfo(T:int) {static auto type() {return ValueType.Int;}}
struct TypeInfo(T:string) {static auto type() {return ValueType.String;}}
struct TypeInfo(T:Date) {static auto type() {return ValueType.Date;}}


struct BasicCell(D,P) {
    alias Driver = D;
    alias Policy = P;
    alias Result = BasicResult!(Driver,Policy);
    alias Bind = Driver.Bind;
    private Bind* bind_;
    private int rowIdx_;

    this(Result *r, Bind *b) {
        bind_ = b;
        rowIdx_ = r.rowIdx_;
    }

    auto bind() {return bind_;}
    auto rowIdx() {return rowIdx_;}
}

struct Converter(D,P) {
    alias Driver = D;
    alias Policy = P;
    alias Result = Driver.Result;
    alias Bind = Driver.Bind;
    alias Cell = BasicCell!(Driver,Policy);

    static Y convert(Y)(Result *r, ref Cell cell) {
        ValueType x = cell.bind.type, y = TypeInfo!Y.type;
        if (x == y) return r.get!Y(&cell); // temporary
        auto e = lookup(x,y);
        if (!e) conversionError(x,y);
        Y value;
        e.convert(r, &cell, &value);
        return value;
    }

    static Y convertDirect(Y)(Result *r, ref Cell cell) {
        assert(b.type == TypeInfo!Y.type);
        return r.get!Y(&cell);
    }

    private:

    struct Elem {
        ValueType from,to;
        void function(Result*,void*,void*) convert;
    }

    // only cross converters, todo: all converters
    static Elem[3] converters = [
    {from: ValueType.Int, to: ValueType.String, &generate!(int,string).convert},
    {from: ValueType.String, to: ValueType.Int, &generate!(string,int).convert},
    {from: ValueType.Date, to: ValueType.String, &generate!(Date,string).convert}
    ];

    static Elem* lookup(ValueType x, ValueType y) {
        // rework into efficient array lookup
        foreach(ref i; converters) {
            if (i.from == x && i.to == y) return &i;
        }
        return null;
    }

    struct generate(X,Y) {
        static void convert(Result *r, void *x_, void *y_) {
            import std.conv;
            Cell* cell = cast(Cell*) x_;
            *cast(Y*) y_ = to!Y(r.get!X(cell));
        }
    }

    static void conversionError(ValueType x, ValueType y) {
        import std.conv;
        string msg;
        msg ~= "unsupported conversion from: " ~ to!string(x) ~ " to " ~ to!string(y);
        throw new DatabaseException(msg);
    }

}
