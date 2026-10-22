--  The language adapters beside Ada's: C and C++, Rust and Python.
--
--  Each reads what a file of its language holds without compiling it: the
--  unit the file is -- a C file's stem, a Rust module's path, a Python
--  module's dotted name -- what it brings in, what it declares at its outer
--  level, and afterwards where the names it can see are used. What is
--  written in the file is explicit; what a name is taken to mean is a
--  naming convention or a heuristic, and says so. None of them is a
--  compiler: a macro, a conditional compilation, a re-export or a dynamic
--  import is not seen through, and what they find is as sure as that.
package Model_Runner.Framework.Repository.Languages is

   --  C and C++: #include "x.h" is a dependency on unit x (a <system>
   --  header is not the project's), a .c or .cpp file implements the unit
   --  its .h declares, and the outer-level functions, types, macros and
   --  classes are its symbols.
   type C_Adapter is new Adapter with null record;

   overriding function Language (Self : C_Adapter) return String;

   overriding procedure Read
     (Self : C_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph);

   overriding procedure Read_References
     (Self : C_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph);

   --  Rust: a file is the module its place under src makes it (lib.rs and
   --  main.rs the crate, mod.rs its directory), use is a dependency, fn,
   --  struct, enum, trait, type, const, static and mod are symbols, a fn in
   --  an impl is its type's, and impl Trait for Type takes on the trait.
   type Rust_Adapter is new Adapter with null record;

   overriding function Language (Self : Rust_Adapter) return String;

   overriding procedure Read
     (Self : Rust_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph);

   overriding procedure Read_References
     (Self : Rust_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph);

   --  Python: a file is the module its path names (a leading src left out,
   --  __init__ its package), import and from ... import are dependencies,
   --  outer-level def and class and upper-case assignments are symbols, a
   --  def in a class is its method, and a class's bases are what it
   --  extends.
   type Python_Adapter is new Adapter with null record;

   overriding function Language (Self : Python_Adapter) return String;

   overriding procedure Read
     (Self : Python_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph);

   overriding procedure Read_References
     (Self : Python_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph);

   --  The adapter that reads a language: Ada's, one of these, or the
   --  generic one that records the file and nothing in it.
   --
   --  @param Language The language, as Language_Of names it.
   --  @return The adapter.
   function Adapter_For (Language : String) return Adapter'Class;

end Model_Runner.Framework.Repository.Languages;
