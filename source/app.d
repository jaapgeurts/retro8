import std.stdio;
import std.file;
import std.string;
import std.conv;
import std.variant;
import std.random : uniform;
import std.range;
import std.array;
import std.algorithm;
import std.algorithm.searching : count;
import core.stdc.stdlib : exit;

import pegged.grammar;

mixin(grammar(`
Retro8:
    Start        <  Unit Import* Sequence Eof
    Unit         <  "unit" Identifier ';'?
    Import       <  "import" Identifier ';'?

    Identifier   <~ [a-zA-Z_]([a-zA-Z_]/[0-9])*

    Sequence     <  ConstList? VarList? ExternList? Function*

    ConstList    <  "constants" '{' Comment* ConstDecl* '}' Comment*
    ConstDecl    <  Identifier '=' Literal ';'?  Comment*

    VarList      <  "variables" Comment* '{'  Comment* VarDecl* '}' Comment*
    VarDecl      <  SimpleDecl Comment* ';'?  Comment*
    #              / arraydecl ';'?

    ExternList   < "extern" Comment* '{' Comment* Prototype* '}' Comment*

    SimpleDecl   <  Identifier ':' Type TypeSuffix? (':=' Literal)?
    Type         <-  "ubyte"
                  / "byte"
                  / "uword"
                  / "word"
                  / "bool"
    TypeSuffix < '[' (DecLit/HexLit)? ']'

    #RegType      < Register '!' Type # add this

    Literal      <-  HexLit /  BinLit / OctLit / DecLit / BoolLit / CharLit / StringLit
    DecLit       <~ [0-9]+
    BinLit       <~ "0b" [0-1]+
    OctLit       <~ "0o" [0-7]+
    HexLit       <~ "0x" ( [0-9A-Fa-f] [0-9A-Fa-f] )+
    BoolLit      <- "true" / "false" 
    CharLit      <~ :quote (!quote ((backslash [bnrt]) / .)) :quote
    StringLit    <- :doublequote ~((!(doublequote / eol)  .)*) :doublequote

    Function     <  "function" Comment* Signature Comment* StatementBlock Comment*
    Prototype    <  "function" Comment* ProtoSignature Comment* 

    Signature    <  Identifier Parameters (':' Register '!' Type )?
    Parameters   < '(' ParamList? ')'
    ParamList    <   Identifier ':' Register '!' Type TypeSuffix? (',' ParamList )?

    ProtoSignature    <  Identifier ProtoParameters (':' Register '!' Type )?
    ProtoParameters   < '(' ParamTypeList? ')'
    ParamTypeList     < Register '!' Type TypeSuffix? (',' ParamTypeList )?

    LocalVarDecl   <  Identifier ':' Register '!' Type TypeSuffix?

    StatementBlock < '{' Comment* LocalVarDecl* Comment* StatementList* '}' 
    StatementList  < Statement Comment* ';'? Comment* (StatementList)*

    Statement       < UnaryExpression
                     / AssignmentStmt 
                     / ReturnStmt
                     / IfStmt
                     / LoopStmt
                     / RepeatUntilStmt
                     / BreakStmt
                     / WhileStmt
                     / FuncCall
                     / AsmStmt

    AssignmentStmt   <  (Identifier / IndirectAccess / Port) ':=' Expression
    ReturnStmt       < "return" Expression?
    BreakStmt        < "break"
    
    LoopStmt         < "loop" StatementBlock

    RepeatUntilStmt  < "repeat" StatementBlock "until" Expression

 
    IfStmt           < "if" Expression StatementBlock ("else" StatementBlock)?
    WhileStmt        < "while" Expression StatementBlock

    UnaryExpression  < Identifier PostfixOp
    PostfixOp        <- '++' / '--'

    Expression        < SimpleExpression (RelationOp SimpleExpression)?
    SimpleExpression <  ( '+' / '-' )? Term (AddOp Term)*
    Term             <  Factor (MulOp Factor)*

    Factor        <  Literal
                    / FuncCall
                    / Port
                    / Identifier
                    / IndirectAccess
                    / '(' Expression ')'
                    / "null"

    IndirectAccess   < '[' (Identifier / Literal) ']'

    Port             < '#' (Identifier /Literal)
    
    Register         <- "AF" / "BC" / "DE" / "HL" / "IX" / "IY" / [ABCDEFHL]
    
    ExprList      <  Expression (',' Expression)*

    RelationOp    <  '<=' / '>=' / '!=' / '=' / '<' / '>' 
    AddOp         <   "or" / '+' / '-'
    MulOp         <  '%' / '*' / '/' / "and"
                
    FuncCall     <  Identifier '(' ArgList* ')'

    AsmStmt      <  "asm" '{' RawAsm '}'
    RawAsm       <- ~(!'}' .)*

    ArgList      <  Expression (',' Expression )*

    Comment      <- LineComment / BlockComment
    LineComment  <~ "//" ( !eol . )* eol
    BlockComment <~ "/*" (!"*/" .)* "*/"

    WhiteSpace     <- Eol / ' ' / '\t'

    Eol          <- "\r\n" / '\n' / '\r'
    Eof          <- !.

`));

enum Register {
    AF,
    BC,
    DE,
    HL,
    IX,
    IY,
    A,
    B,
    C,
    D,
    E,
    F,
    H,
    L
}

enum Kind {
    None,
    Constant,
    Variable,
    Register,
    Function
}

enum Type {
    None,
    Bool,
    Byte,
    Word,
}

struct Param {
    string register; // should use enum here
    Type type;
    bool isIndirection;
}

class Symbol {
    Kind kind = Kind.None;
    string name;
    Type type;
    bool isSigned;
    bool isIndirection;
    bool isString; // for internal use only
    string value;
    string code;
    string register;
    Param[] funcargs;
    int count = 1;

    public this(Kind kind, string name, Type type, string register, bool signed,
            bool indirection, bool isString, string value, string code, int count) {
        this.kind = kind;
        this.name = name;
        this.type = type;
        this.register = register;
        isSigned = signed;
        isIndirection = indirection;
        this.isString = isString;
        this.value = value;
        this.register = register;
        this.count = count;
    }
}

Symbol[string] symboltable;

class LocalScope {
    Symbol[string] symbols;
}

LocalScope[] localsymbolstack;

string genIdentifier() {
    char[] rnd = generate!(() => uniform(0, 26) + 'a').takeExactly(10).map!(v => cast(char) v)
        .array;
    return rnd.idup;
}

void main(string[] args) {

    if (args.length != 2) {
        stderr.writefln("USAGE %s <filename>", args[0]);
    }

    string input = readText(args[1]);

    // Parsing at compile-time:
    ParseTree parseTree1 = Retro8(input);

    //  parseTree1 = simplifyTree(parseTree1);

    // pragma(msg, parseTree1.matches);
    stderr.writeln(parseTree1);

    // TODO: make it two pass.

    emitAssembly(parseTree1, 0);

    emitConst();

    emitData();

}

void emitConst() {
    writeln("; List of constants");
    foreach (v; symboltable.values.filter!(a => !a.isString
            && (a.type == Type.Byte || a.type == Type.Word) && a.kind == Kind.Constant)) {
        // todo check if there is an array.
        string tabs = generate!(() => '\t').takeExactly((23 - v.name.length) / 8 + 1).array;
        writeln(v.name, "\tequ\t", v.value, "\t\t; ", v.code);
    }
}

string toAsmStr(string src) {
    string dst = "";
    int count = 0;
    bool instring = false;

    int i = 0;
    while (i < src.length) {
        char c = src[i];
        if (c != '\\') { // normal char
            if (!instring) {
                dst ~= "\"";
                instring = true;
            }
            dst ~= c;
        }
        else { // escaped char
            if (instring) {
                dst ~= "\",";
                instring = false;
            }
            dst ~= to!string(unEscapeCharLiteral(src[i .. i + 2])) ~ ",";
            i++;
        }
        count++;
        i++;
    }
    if (instring)
        dst ~= '\"';
    else if (count > 0)
        dst = dst[0 .. $ - 1];

    if (count > 0) {
        dst = to!string(count) ~ "," ~ dst;
    }

    return dst;
}

unittest {
    string str;
    str = toAsmStr("");
    assert(str == "", str);
    assert(toAsmStr("a") == `1,"a"`);
    assert(toAsmStr("ab") == `2,"ab"`);
    assert(toAsmStr("abc") == `3,"abc"`);
    str = toAsmStr(r"\n");
    assert(str == "1,10", str);
    assert(toAsmStr(r"\n\r") == "2,10,13");
    str = toAsmStr(r"a\n");
    assert(str == `2,"a",10`,str);
    assert(toAsmStr(r"ab\n") == `3,"ab",10`);
    assert(toAsmStr(r"abc\n") == `4,"abc",10`);
    assert(toAsmStr(r"\na") == `2,10,"a"`);
    assert(toAsmStr(r"\nab") == `3,10,"ab"`);
    assert(toAsmStr(r"\nabc") == `4,10,"abc"`);
    assert(toAsmStr(r"a\na") == `3,"a",10,"a"`);
    assert(toAsmStr(r"ab\nab") == `5,"ab",10,"ab"`);
    assert(toAsmStr(r"abc\nabc") == `7,"abc",10,"abc"`);
}

void emitData() {
    writeln("; variables and strings");
    foreach (v; symboltable.values.sort!((a, b) => a.isString == b.isString
            ? false : (a.isString ? false : true))) {
        // todo check if there is an array.
        string tabs = generate!(() => '\t').takeExactly((24 - v.name.length) / 8 + 1).array;
        if (v.kind == Kind.Variable) {
            switch (v.type) {
            case Type.Byte:
                if (v.isString) {
                    writeln(v.name, ":", tabs, "ascii ", toAsmStr(v.value));
                }
                else {
                    string value = v.value;
                    if (value == "")
                        value = "0";
                    if (v.count > 1)
                        writeln(v.name, ":", tabs, "dc    ", v.count, ",",
                                value, "\t\t; ", v.code);
                    else
                        writeln(v.name, ":", tabs, "db    ", value, "\t\t; ", v.code);
                }

                break;
            case Type.Word:
                writeln(v.name, ":", tabs, "word ", v.value, "\t\t; ", v.code);
                break;
            default:
                writeln("Unknown type: ", v);
                break;
            }
        }
        else if (v.kind == Kind.Constant) {
            if (v.type == Type.Byte && v.isString) {
                writeln(v.name, ":", tabs, "ascii ", toAsmStr(v.value));
            }
        }
    }
}

Type textToType(string typename) {
    switch (typename) {
    case "byte":
    case "ubyte":
        return Type.Byte;
    case "word":
    case "uword":
        return Type.Word;
    case "bool":
        return Type.Bool;
    default:
        return Type.None;
    }
}

bool isTypeSigned(string typename) {
    return typename[0] == 'u';
}

void emitSimpleDecl(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]);
    immutable Type type = textToType(node.matches[2]);
    bool isSigned = isTypeSigned(node.matches[2]);
    string identifier = node.matches[0];
    bool indirection = node.children.length >= 3 && node.children[2].name == "Retro8.TypeSuffix";
    int count = 0;
    string value = "";
    if (node.children.length > 2 && node.children[2].children.length > 0) {
        if (node.children[2].name == "Retro8.TypeSuffix")
            count = to!int(node.children[2].children[0].matches[0]);
        else if (node.children[2].name == "Retro8.Literal")
            value = node.children[2].children[0].matches[0];
    }

    // add name to symbol tables
    Symbol symbol = new Symbol(Kind.Variable, "v_" ~ identifier, type, "",
            isSigned, indirection, false, value, srctext, count);
    if (node.children.length > 3)
        symbol.value = node.matches[4];
    symboltable[identifier] = symbol;

    // do type checks here
}

void recordPrototypeParams(ParseTree node, Symbol s) {
    if (node.name == "Retro8.ProtoParameters") {
        if (node.children.length > 0)
            recordPrototypeParams(node.children[0], s);
    }
    else if (node.name == "Retro8.ParamTypeList") {
        bool indirection = node.children.length >= 3 && node.children[2].name == "Retro8.TypeSuffix";
        Param param = {
            node.children[0].matches[0].toLower(),
                textToType(node.children[1].matches[0]), indirection
        };
        s.funcargs ~= param;
        if (node.children.length >= 3) {
            if (node.children[2].name == "Retro8.ParamTypeList") {
                recordPrototypeParams(node.children[2], s);
            }
            else if (node.children.length >= 4) {
                recordPrototypeParams(node.children[3], s);
            }
        }
    }
}

void recordPrototype(ParseTree node) {
    string ident = node.children[0].matches[0];
    Symbol s = new Symbol(Kind.Function, ident, Type.None, "", false, false, false, "", "", 0);
    recordPrototypeParams(node.children[1], s);
    symboltable[ident] = s;

}

void recordConstDecl(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]);
    immutable string identifier = node.children[0].matches[0];
    node = node.children[1];
    immutable string literaltype = node.children[0].name;
    switch (literaltype) {
    case "Retro8.DecLit":
        // todo: check size
        Symbol symbol = new Symbol(Kind.Constant, identifier, Type.Byte, "",
                false, false, false, node.children[0].matches[0], srctext, 0);
        symboltable[identifier] = symbol;
        break;
    case "Retro8.HexLit":
        // todo: check size
        Symbol symbol = new Symbol(Kind.Constant, identifier, Type.Byte, "",
                false, false, false, node.children[0].matches[0], srctext, 0);
        symboltable[identifier] = symbol;
        break;
    case "Retro8.StringLit":
        Symbol symbol = new Symbol(Kind.Constant, identifier, Type.Byte, "",
                false, true, true, node.children[0].matches[0], srctext, 0);
        symboltable[identifier] = symbol;
        break;
    default:
        break;
    }
}

void emitAssembly(ParseTree root, int level) {
    foreach (ref node; root.children) {
        switch (node.name) {
        case "Retro8.ConstDecl":
            recordConstDecl(node);
            break;
        case "Retro8.ProtoSignature":
            recordPrototype(node);
            break;
        case "Retro8.SimpleDecl":
            emitSimpleDecl(node);
            break;
        case "Retro8.Function":
            emitFunctionStart(node);
            emitStatementBlock(node.children[1]);
            emitFunctionEnd(node);
            break;
        default:
            emitAssembly(node, level + 1);
            //                writeln("Error unknown node: " ~ node.name);
            break;
        }
    }
}

void emitStatement(ParseTree node) {
    switch (node.name) {
    case "Retro8.AssignmentStmt":
        emitAssignmentStmt(node);
        break;
    case "Retro8.FuncCall":
        emitFunctionCall(node);
        break;
    case "Retro8.IfStmt":
        emitIfStatement(node);
        break;
    case "Retro8.WhileStmt":
        emitWhileStatement(node);
        break;
    case "Retro8.RepeatUntilStmt":
        emitRepeatUntilStatement(node);
        break;
    case "Retro8.LoopStmt":
        emitLoopStatement(node);
        break;
    case "Retro8.BreakStmt":
        emitBreakStatement(node);
        break;
    case "Retro8.ReturnStmt":
        emitReturnStatement(node);
        break;
    case "Retro8.UnaryExpression":
        emitUnaryExprStatement(node);
        break;
    case "Retro8.AsmStmt":
        writeln(node.children[0].matches[0]);
        break;
    default:
        // just descend
        emitStatementList(node);
        break;
    }
}

void emitUnaryExprStatement(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]);
    bool indirect = node.children[0].name == "Retro8.IndirectAccess";

    if (indirect)
        node = node.children[0];

    string identifier = node.children[0].matches[0];
    string operator = node.children[1].matches[0];
    Symbol s = getSymbolForIdentifier(node.children[0]);
    string op = "  inc  ";
    if (operator == "--")
        op = "  dec  ";
    if (s.kind == Kind.Register) {
        writeln(op, s.register, "\t\t; ", srctext);
    }
    else if (s.kind == Kind.Variable) {
        if (indirect)
            writeln(op, "(", s.name, ")\t\t; ", srctext);
        else
            stderr.writeln("** ERROR ** Can't increment global variable addresses");
    }
}

void processLocalDecl(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]);
    immutable Type type = textToType(node.matches[2]);
    bool isSigned = isTypeSigned(node.matches[2]);
    string identifier = node.children[0].matches[0];
    bool indirection = node.children.length > 3 && node.children[3].name == "Retro8.TypeSuffix";
    int count = 0;
    string value = "";

    string register = node.children[1].matches[0].toLower();
    // add name to symbol tables
    Symbol symbol = new Symbol(Kind.Register, identifier, type, register,
            isSigned, indirection, false, value, srctext, count);

    localsymbolstack.back.symbols[identifier] = symbol;

}

void emitStatementList(ParseTree node) {
    foreach (child; node.children)
        emitStatement(child);
}

void emitStatementBlock(ParseTree node) {
    // don't create a new scope. It has been created by the function already
    foreach (child; node.children) {
        if (child.name == "Retro8.LocalVarDecl") {
            processLocalDecl(child);
        }
        if (child.name == "Retro8.StatementList") {
            emitStatementList(child);
        }
    }
}

void emitIfStatement(ParseTree node) {
    ParseTree child = node.children[0];
    immutable string endLabel = "endif_" ~ genIdentifier();
    immutable string elseLabel = "else_" ~ genIdentifier();
    immutable string srctxt = "if " ~ strip(child.input[child.begin .. child.end]);
    writeln("\t\t\t; ", srctxt);
    emitExpression(child); // result ends up in register 'a'
    writeln("  cp   1\t\t; " ~ srctxt);
    if (node.children.length > 2)
        writeln("  jr   nz," ~ elseLabel);
    else
        writeln("  jr   nz," ~ endLabel);
    if (node.children[1].children.length > 0)
        emitStatementList(node.children[1].children[0]);
    if (node.children.length > 2) {
        // jump over else
        writeln("  jr   ", endLabel);
        writeln(elseLabel, ":\t\t; else");
        // we have an else block
        if (node.children[2].children.length > 0)
            emitStatementList(node.children[2].children[0]);
    }
    writeln(endLabel, ":\t; endif");

}

void emitBreakStatement(ParseTree node) {
    writeln("  break ; TODO BREAK NOT IMPLEMENTED");
}

void emitWhileStatement(ParseTree node) {

    ParseTree child = node.children[0];

    string srctext = strip(child.input[child.begin .. child.end]);

    immutable string labelEnd = "wend_" ~ genIdentifier();
    immutable string labelLoop = "while_" ~ genIdentifier();
    writeln(labelLoop ~ ":\t; while ", srctext);
    emitExpression(child); // result ends up in register 'a'
    writeln("  cp   1");
    writeln("  jr   nz,", labelEnd);
    emitStatementList(node.children[1]);
    writeln("  jp   ", labelLoop, "\t; wend ", srctext);
    writeln(labelEnd, ":");
}

void emitRepeatUntilStatement(ParseTree node) {

    ParseTree child = node.children[1];
    immutable string labelLoop = "repeat_" ~ genIdentifier();
    writeln(labelLoop ~ ":\t\t; repeat");
    emitStatementList(node.children[0]);
    emitExpression(child); // result ends up in register 'a'
    writeln("  cp   1\t\t; ");

    string srctext = strip(child.input[child.begin .. child.end]);

    writeln("  jr  nz,", labelLoop, "\t\t; until ", srctext);
}

void emitLoopStatement(ParseTree node) {

    immutable string labelLoop = "loop_" ~ genIdentifier();
    writeln(labelLoop, ":\t; loop");
    emitStatementList(node.children[0]);
    writeln("  jp   ", labelLoop, "\t; endloop");
}

void emitReturnStatement(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]);

    if (node.children.length > 0)
        emitExpression(node.children[0]);
    writeln("  ret\t\t\t; ", srctext);
}

Symbol getSymbolForIdentifier(ParseTree node) {
    string identlit = node.matches[0];

    if (identlit in localsymbolstack.back.symbols) {
        return localsymbolstack.back.symbols[identlit];
    }
    else if (identlit in symboltable) {
        return symboltable[identlit];
    }

    // not in any symbol table
    stderr.writeln("Unknown identifier near: " ~ node.input[node.begin .. node.end]);
    exit(1);
    return null;
}

ubyte unEscapeCharLiteral(string s) {
    if (s[0] == '\\') {
        switch (s[1]) {
        case 'r':
            return 13;
        case 'n':
            return 10;
        case 't':
            return 9;
        case 'b':
            return 8;
        case '\\':
            return '\\';
        default:
            stderr.writeln("** ERROR ** Unsupported character literal: ", s[1]);
            exit(1);
        }
    }
    return s[0];
}

Type emitLiteral(ParseTree node) {
    string literal = node.matches[0];

    switch (node.name) {
    case "Retro8.DecLit":
    case "Retro8.HexLit":
    case "Retro8.BinLit":
    case "Retro8.OctLit":
        // TODO: convert the literal. If larger than 8 bit
        writeln("  ld   a,", literal);
        return Type.Byte;
    case "Retro8.CharLit":
        writeln("  ld   a,", unEscapeCharLiteral(literal));
        return Type.Byte;
    case "Retro8.BoolLit":
        writeln("  ld   a,", (literal == "true" ? "1" : "0"));
        return Type.Bool;
    case "Retro8.StringLit":
        // string literal found. put it constant list
        string identifier = genIdentifier();
        Symbol symbol = new Symbol(Kind.Constant, identifier, Type.Byte, "",
                false, true, true, literal, "", 0);
        symboltable[identifier] = symbol;
        writeln("  ld   bc,", identifier, "\t; ad-hoc string literal");
        return Type.Word;
    default:
        stderr.writeln("Unknown literal type: ", node.name);
        break;
    }
    return Type.Byte;
}

Type emitIdentifier(ParseTree node) {
    // variable or constant (i.e. memory, constant or register)
    Symbol s = getSymbolForIdentifier(node);

    Type type = s.type;

    switch (s.kind) {
    case Kind.Constant:
        if (s.isIndirection)
            writeln("  ld   bc,", s.name,
                    "\t; constant indirection ", __LINE__);
        else
            writeln("  ld   a,", s.name, "\t\t; constant no indirection ", __LINE__);
        break;
    case Kind.Variable:
        if (s.isIndirection) {
            writeln("  ld   bc,", s.name, "\t\t; variable indirection ", __LINE__);
            type = Type.Word;
        }
        else
            writeln("  ld   a,(", s.name, ")\t\t; variable no indirection ", __LINE__);
        break;
    case Kind.Register:
        if (s.register[0] != 'a')
            writeln("  ld   a,", s.register, "\t\t; register");
        break;
    default:
        stderr.writeln("Internal compiler error. Unknown symbol");
        break;
    }

    return type;

}

Type emitPortRead(ParseTree node) {
    // resolve the symbol if it's an identifier
    string srctext = strip(node.input[node.begin .. node.end]);
    string port;
    if (node.children[0].name == "Retro8.Identifier") {
        Symbol s = getSymbolForIdentifier(node.children[0]);
        if (s.kind == Kind.Constant) {
            port = s.name;
            writeln("  in   a,(", port, ")\t\t; ", srctext);
        }
        else if (s.kind == Kind.Variable) {
            writeln("  ld   c,(", s.name, ")");
            writeln("  in   a,c\t\t; ", srctext);
        }
    }
    return Type.Byte;
}

Type emitRegister(ParseTree node) {
    string register = node.matches[0].toLower();
    if (register[0] != 'a')
        writeln("  ld   a,", register, "\t\t; emitRegister ", __LINE__);
    switch (register.toUpper()) {
    case "AF":
    case "BC":
    case "DE":
    case "HL":
    case "IX":
    case "IY":
        return Type.Word;
    default:
        return Type.Byte;
    }
}

Type emitEvalOperation(ParseTree node) {
    ParseTree op1 = node.children[0];
    ParseTree op2 = node.children[2];
    Type type = Type.Byte;
    // check if we have to descend first
    if (op1.name == "Retro8.SimpleExpression" || op1.name == "Retro8.Term"
            || op1.name == "Retro8.Expression") {
        Type type1 = emitExpression(op1);
        //writeln("  ld   c,a\t\t; store result from op1"); // move a to c
        writeln("  push af\t\t; store result from op1");
        Type type2 = emitExpression(op2);
        if (type1 == Type.Word || type2 == Type.Word)
            type = Type.Word;
        writeln("  ld   b,a\t\t; swap operands");
        writeln("  pop  af\t\t; fetch stored result");
    }
    else {
        Type type1 = emitExpression(op2);
        writeln("  ld   b,a\t\t; store result 3");
        Type type2 = emitExpression(op1);
        if (type1 == Type.Word || type2 == Type.Word)
            type = Type.Word;
    }
    // apply operator

    // emit operator
    switch (node.children[1].name) {
    case "Retro8.AddOp":
        switch (node.children[1].matches[0]) {
        case "+":
            writeln("  add  b");
            break;
        case "-":
            writeln("  sub  b");
            break;
        default:
            break;
        }
        break;
    case "Retro8.MulOp":
        switch (node.children[1].matches[0]) {
        case "*":
            writeln("  call mul");
            break;
        case "/":
            writeln("  call div");
            break;
        case "%":
            writeln("  call div");
            break;
        default:
            break;
        }
        break;
    case "Retro8.RelationOp":
        type = Type.Bool;
        writeln("  cp   b");
        // assume false
        writeln("  ld   a,0\t\t; false");
        string lblEnd = "false_" ~ genIdentifier();
        switch (node.children[1].matches[0]) {
        case "=":
            writeln("  jr   nz," ~ lblEnd);
            break;
        case "!=":
            writeln("  jr   z," ~ lblEnd);
            break;
        case "<":
            writeln("  jr   nc," ~ lblEnd);
            break;
        case ">":
            writeln("  jr   c," ~ lblEnd);
            break;
        case "<=":
            writeln("  jr   c," ~ lblEnd);
            writeln("  jr   nz," ~ lblEnd);
            break;
        case ">=":
            writeln("  jr   nc," ~ lblEnd);
            writeln("  jr   nz," ~ lblEnd);
            break;
        default:
            break;
        }
        writeln("  ld   a,1\t\t; true");
        writeln(lblEnd ~ ":");
        break;
    default:
        break;
    }
    return type;
}

Type emitExpression(ParseTree node) {
    Type type = Type.Byte;
    switch (node.name) {
    case "Retro8.Register":
        return emitRegister(node);
    case "Retro8.Literal":
        return emitLiteral(node.children[0]);
    case "Retro8.Identifier":
        return emitIdentifier(node);
    case "Retro8.Port":
        return emitPortRead(node);
    case "Retro8.IndirectAccess":
        Symbol s = getSymbolForIdentifier(node.children[0]);
        switch (s.kind) {
        case Kind.Constant:
            writeln("  ld   a,(", s.name, ")\t\t; constant ", __LINE__);
            break;
        case Kind.Register:
            writeln("  ld   a,(", s.register, ")\t\t; register ", __LINE__);
            break;
        case Kind.Variable:
            if (!s.isIndirection)
                stderr.writeln("WARNING: using byte as pointer ", __LINE__);
            writeln("  ld   hl,(", s.name, ")\t\tvariable ", __LINE__);
            writeln("  ld   a,(hl)");
            break;
        default:
            stderr.writeln(" *** ERROR ***", __LINE__);
        }
        break;
    case "Retro8.Factor":
    case "Retro8.SimpleExpression":
    case "Retro8.Term":
    case "Retro8.Expression":
        if (node.children.length == 1)
            return emitExpression(node.children[0]);
        else if (node.children.length == 3)
            return emitEvalOperation(node);
        break;
    case "Retro8.FuncCall":
        return emitFunctionCall(node);
    default:
        // TODO: consider the type
        if (node.children.length > 1)
            stderr.writeln("** WARNING ** more than one child ", __LINE__);
        foreach (ParseTree child; node.children) {
            return emitExpression(child);
        }
        break;
    }
    return type;
}

Type emitFunctionCall(ParseTree node) {
    //foreach argument in the list
    Symbol s = getSymbolForIdentifier(node.children[0]);
    // get the symbol for this function call
    if (s.kind != Kind.Function) {
        stderr.writeln("** ERROR ** symbol ", node.children[0].matches[0],
                " is not a function. ", __LINE__);
        exit(1);
    }
    if (node.children.length > 1) {
        foreach (i, arg; node.children[1].children) {
            Param p = s.funcargs[i];
            if (p.register == "bc" || p.register == "a")
                continue; // do A or BC register last
            Type type = emitExpression(arg);
            // TODO: check signature and put the arguments in the correct registers
            if (type == Type.Bool || type == Type.Byte) {
                writeln("  ld   ", p.register, ",a");
            }
            else {
                writeln("  push bc\t\t; ld ", p.register, ",bc");
                writeln("  pop  ", p.register);
            }
        }
        foreach (i, arg; node.children[1].children) {
            Param p = s.funcargs[i];
            if (p.register != "bc" && p.register != "a")
                continue;
            emitExpression(arg);
        }
    }
    string identifier = node.children[0].matches[0];
    string instruction = "  call " ~ identifier;
    string tabs = generate!(() => '\t').takeExactly((23 - instruction.length) / 8 + 1).array;
    writeln(instruction, tabs, "; " ~ strip(node.input[node.begin .. node.end]));
    return s.type;
}

void processParamList(ParseTree node, Symbol s) {
    string register = node.children[1].matches[0].toLower();
    Type type = textToType(node.children[2].matches[0]);
    bool isIndirection = false;
    if (node.children.length > 3)
        isIndirection = node.children[3].name == "Retro8.TypeSuffix";
    string identifier = node.children[0].matches[0];
    bool isSigned = isTypeSigned(node.matches[2]);

    Symbol ls = new Symbol(Kind.Register, identifier, type, register, isSigned,
            isIndirection, false, "", "", 0);

    localsymbolstack.back.symbols[identifier] = ls;
    Param p = {register, type, isIndirection};
    s.funcargs ~= p;
    if (isIndirection) {
        if (node.children.length > 4) {
            processParamList(node.children[4], s);
        }
    }
    else {
        if (node.children.length > 3) {
            processParamList(node.children[3], s);
        }
    }
}

void emitFunctionSignature(ParseTree node) {

    string identifier = node.children[0].matches[0];
    // record  in local symbol table
    LocalScope ls = new LocalScope();
    localsymbolstack ~= ls;

    Type type = Type.None;
    bool isSigned = false;
    if (node.children.length > 2) {
        type = textToType(node.children[3].matches[0]);
        isSigned = isTypeSigned(node.children[3].matches[0]);
    }
    // add the function to the global symbol table
    Symbol s = new Symbol(Kind.Function, identifier, type, "", isSigned, false, false, "", "", 0);
    if (node.children[1].children.length > 0) {
        processParamList(node.children[1].children[0], s);
    }
    symboltable[identifier] = s;
    writeln(node.matches[0] ~ ":\t\t\t; " ~ strip(node.input[node.begin .. node.end]));
}

void emitFunctionStart(ParseTree node) {
    emitFunctionSignature(node.children[0]); // save all registers we're going to use
    /*    if (localsymbolstack.length > 0) {
        Symbol[string] localsymbols = localsymbolstack.back.symbols;
        foreach (Symbol s; localsymbols.values) {
            writeln("  push " ~ s.register);
        }
    }
    writeln("  push hl");
    */
}

void emitFunctionEnd(ParseTree node) {

    // restore registers
    /*    writeln("  pop  hl");
    if (localsymbolstack.length > 0) {
        Symbol[string] localsymbols = localsymbolstack.back.symbols;
        foreach_reverse (Symbol s; localsymbols.values) { // TODO: order is wrong
            writeln("  pop  " ~ s.register);
        }
        // remove variables from symbol table
        localsymbolstack.popBack();
    }
    */
    writeln("  ret");
    localsymbolstack.popBack();
}

void emitAssignmentStmt(ParseTree node) {

    string srctext = strip(node.input[node.begin .. node.end]);

    Type type = emitExpression(node.children[1]);
    bool indirect = false;
    ParseTree identNode;
    if (node.children[0].name == "Retro8.IndirectAccess") {
        indirect = true;
        identNode = node.children[0].children[0];
    }
    else if (node.children[0].name == "Retro8.Port") {
        identNode = node.children[0].children[0];
        Symbol s = getSymbolForIdentifier(identNode);
        if (s.kind == Kind.Constant) {
            writeln("  out  (", s.name, "),a\t\t; ", srctext);
        }
        else if (s.kind == Kind.Variable) {
            writeln("  ld   a,", s.value, "\t\t; ", srctext);
            writeln("  out  (", s.value, "),a");
        }
        return;
    }
    else {
        identNode = node.children[0];
    }
    Symbol s = getSymbolForIdentifier(identNode);
    // TODO: emit warning. access on indirect if not and vice versa
    string srcreg = "a";
    if (type == Type.Word)
        srcreg = "bc";
    string dstreg = s.name;
    if (s.kind == Kind.Register) {
        dstreg = s.register;
    }
    if (dstreg != srcreg) {
        if (indirect) {
            writeln("  ld   (", dstreg, "),", srcreg, "\t\t; ", srctext);
        }
        else {
            if (dstreg == "de" || dstreg == "hl" || dstreg == "bc") {
                writeln("  push ", srcreg, "\t\t; ld ", dstreg, ",", srcreg, "\t\t; ", srctext);
                writeln("  pop  ", dstreg);
            }
            else {
                writeln("  ld   ", dstreg, ",", srcreg, "\t\t; ", srctext);
            }
        }
    }
}
