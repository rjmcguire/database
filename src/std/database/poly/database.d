module std.database.poly.database;

import std.string;
import core.stdc.stdlib;
import std.conv;

public import std.database.exception;

import std.stdio;
import std.typecons;
import std.container.array;

struct Database {

    static Database create(string defaultURI) {
        return Database(defaultURI);
    }

    // public

    static void register(Database) (string name = "") {
        name = "name"; // synth name
        writeln(
                "poly register: ",
                "name: ", name, ", "
                "type: ", typeid(Database),
                "index: ", databases.length);
        databases ~= Info(name, CreateGen!Database.dispatch);
    }

    this(string defaultURI) {
        foreach(ref d; databases) {
            d.data = d.dispatch.create(defaultURI);
        }
    }

    ~this() {
        foreach(ref d; databases) {
            d.dispatch.destroy(d.data);
        }
    }

    // private

    private struct Dispatch {
        void* function(string defaultURI) create;
        void function(void*) destroy;
    }

    private struct Info {
        string name;
        Dispatch dispatch;
        void *data;
    }

    private static Array!Info databases;

    private template CreateGen(Database) {

        static void* create(string defaultURI) {
            import core.memory : GC;
            auto p = cast(Database*) malloc(Database.sizeof);
            return emplace!Database(p, defaultURI);
            //GC.addRange(p, T.sizeof * values.length);
        }

        static void destroy(void *data) {
            import core.memory : GC;
            //GC.removeRange(data);
            .destroy(*(cast(Database*) data));
            free(data);
        }

        static Dispatch dispatch = {
            &create,
            &destroy
        };
    }

}
