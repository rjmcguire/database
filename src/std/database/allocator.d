module std.database.allocator;
//import std.experimental.allocator.common;
import std.experimental.logger;

struct MyMallocator {
    //enum uint alignment = platformAlignment;

    @trusted // removed @nogc and nothrow for logging
    void[] allocate(size_t bytes) {
        import core.stdc.stdlib : malloc;
        if (!bytes) return null;
        auto p = malloc(bytes);
	//log("allocate: ptr: ", p , "  size :",bytes);
        return p ? p[0 .. bytes] : null;
    }

    /// Ditto
    @system // removed @nogc and nothrow for logging
    bool deallocate(void[] b) {
        import core.stdc.stdlib : free;
        //log("deallocate: ptr: ", b.ptr, "   size: ", b.length);
        free(b.ptr);
	//log("return true");
        return true;
    }

}

