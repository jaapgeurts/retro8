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

    ConstList    <  "constants" '{' ConstDecl* '}' Comment*
    ConstDecl    <  Identifier '=' Literal ';'?

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
    TypeSuffix    < '[]'

    Literal      <-  DecLit / BinLit / OctLit / HexLit / BoolLit / StringLit
    DecLit       <~ [0-9]+
    BinLit       <~ '0b' [0-1]+
    OctLit       <~ '0o' [0-7]+
    HexLit       <~ '0x' ([0-9A-F][0-9A-F])+
    BoolLit      <- "true" / "false" 
    StringLit    <- :doublequote ~((!(doublequote / eol)  .)*) :doublequote

    Function     <  "function" Comment* Signature Comment* StatementBlock Comment*
    Prototype    <  "function" Comment* ProtoSignature Comment* 

    Signature    <  Identifier Parameters (':' Register '!' Type )?
    Parameters   < '(' ParamList? ')'
    ParamList    <   Register '!' Type TypeSuffix? Identifier (',' ParamList )?

    ProtoSignature    <  Identifier ProtoParameters (':' Register '!' Type )?
    ProtoParameters   < '(' ParamTypeList? ')'
    ParamTypeList     <  Register '!' Type TypeSuffix? Identifier? (',' ParamTypeList )?

    StatementBlock < '{' Comment* StatementList* '}' 
    StatementList  < Statement Comment* ';'? Comment* (StatementList)*

    Statement       < UnaryExpression
                     / AssignmentStmt 
                     / ReturnStmt
                     / IfStmt
                     / WhileStmt
                     / FuncCall

    AssignmentStmt   <  (Identifier / RegisterLit / IndirectAccess) ':=' Expression
    ReturnStmt       < "return" Expression
 
    IfStmt           < "if" Expression StatementBlock ("else" StatementBlock)?
    WhileStmt        < "while" Expression StatementBlock

    UnaryExpression  < (Identifier / RegisterLit) PostfixOp
    PostfixOp        <- '++' / '--'

    Expression        < SimpleExpression (RelationOp SimpleExpression)?
    SimpleExpression <  ( '+' / '-' )? Term (AddOp Term)*
    Term             <  Factor (MulOp Factor)*

    Factor        <  Literal
                    / FuncCall
                    / Identifier
                    / RegisterLit
                    / IndirectAccess
                    / '(' Expression ')'
                    / "null"

    IndirectAccess   < '[' (Identifier / Literal / RegisterLit) ']'
    
    RegisterLit      <- '#' Register
    Register         <- "AF" / "BC" / "DE" / "HL" / "IX" / "IY" / [ABCDEFHL]
    
    ExprList      <  Expression (',' Expression)*

    RelationOp    <  '<=' / '>=' / '!=' / '=' / '<' / '>' 
    AddOp         <   "||" / '+' / '-'
    MulOp         <  '%' / '*' / '/' / "&&"
                
    FuncCall     <  Identifier '(' ArgList* ')'

    ArgList      <  Expression (',' Expression )*

    Comment      <- LineComment / BlockComment
    LineComment  <~ "//" ( !eol . )* eol
    BlockComment <~ "/*" (!"*/" .)* "*/"

    WhiteSpace     <- Eol / ' ' / '\t'

    Eol          <- "\r\n" / '\n' / '\r'
    Eof          <- !.

`));
/*
    Term     < Factor (Add / Sub)*
    Add      < "+" Factor
    Sub      < "-" Factor
    Factor   < Primary (Mul / Div)*
    Mul      < "*" Primary
    Div      < "/" Primary
    Primary  < Parens / Neg / Number / Variable
    Parens   < "(" Term ")"
    Neg      < "-" Primary
    Number   < ~([0-9]+)
    Variable <- identifier*/

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

struct Symbol {
    Kind kind = Kind.None;
    string name;
    Type type;
    bool signed;
    bool indirection;
    bool isString; // for internal use only
    string value;
    string code;
    string register;
    Param[] funcargs;
}

Symbol[string] symboltable;

struct LocalScope {
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
    writeln(parseTree1);

    emitAssembly(parseTree1, 0);

    emitData();

}

void emitData() {
    foreach (v; symboltable.values.sort!((a, b) => a.isString == b.isString
            ? false : (a.isString ? false : true))) {
        // todo check if there is an array.
        if (v.kind == Kind.Variable || (v.kind == Kind.Constant)) {
            string tabs = generate!(() => '\t').takeExactly((24 - v.name.length) / 8 + 1).array;
            switch (v.type) {
            case Type.Byte:
                if (v.isString) {
                    writeln(v.name, ":", tabs, ".ascii ",
                            to!string(v.value.length - v.value.count('\\')), ",\"", v.value, "\"");
                }
                else {
                    writeln(v.name, ":", tabs, ".byte ", v.value, "\t\t; ", v.code);
                }

                break;
            case Type.Word:
                writeln(v.name, ":", tabs, ".word ", v.value, "\t\t; ", v.code);
                break;
            default:
                writeln("Unknown type: ", v);
                break;
            }
        }
    }
}

void recordPrototypeParams(ParseTree node, Symbol* s) {
    if (node.name == "Retro8.ProtoParameters") {
        if (node.children.length > 0)
            recordPrototypeParams(node.children[0], s);
    }
    else if (node.name == "Retro8.ParamTypeList") {
        bool indirection = node.children.length >= 3 && node.children[2].name == "Retro8.TypeSuffix";
        Param param = {
            node.children[0].matches[0], textToType(node.children[1].matches[0]), indirection
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
    Symbol s = {Kind.Function, ident, Type.None, false, false, false, "", ""};
    recordPrototypeParams(node.children[1], &s);
    symboltable[ident] = s;

}

void emitAssembly(ParseTree root, int level) {
    foreach (ref node; root.children) {
        switch (node.name) {
        case "Retro8.ConstDecl":
            immutable string identifier = node.children[0].matches[0];
            immutable string literaltype = node.children[1].name;
            string srctext = strip(node.input[node.begin .. node.end]);
            switch (literaltype) {
            case "Retro8.DecLit":
                // todo: check size
                Symbol symbol = {
                    Kind.Constant, identifier, Type.Byte, false, false, false,
                        node.children[1].matches[0], srctext
                };
                symboltable[identifier] = symbol;
                break;
            case "Retro8.StringLit":
                Symbol symbol = {
                    Kind.Constant, identifier, Type.Byte, true, true, false,
                        node.children[1].matches[0], srctext
                };
                symboltable[identifier] = symbol;
                break;
            default:
                break;
            }
            break;
        case "Retro8.ProtoSignature":
            recordPrototype(node);
            break;
        case "Retro8.SimpleDecl":
            emitSimpleDecl(node);
            break;
        case "Retro8.Function":
            emitFunctionStart(node);
            emitStatementList(node.children[1]);
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
    case "Retro8.ReturnStmt":
        emitReturnStatement(node);
        break;
    default:
        // just descend
        emitStatementList(node);
        break;
    }
}

void emitStatementList(ParseTree node) {
    foreach (child; node.children) {
        emitStatement(child);
    }
}

void emitIfStatement(ParseTree node) {
    ParseTree child = node.children[0];
    immutable string label = "endif_" ~ genIdentifier();
    immutable string srctxt = "if " ~ strip(child.input[child.begin .. child.end]);
    emitExpression(child); // result ends up in register 'a'
    writeln("  cp   1\t\t; " ~ srctxt);
    writeln("  jr   nz," ~ label);
    emitStatementList(node.children[1]);
    writeln(label ~ ":");
}

void emitWhileStatement(ParseTree node) {
    ParseTree child = node.children[0];
    immutable string labelEnd = "wend_" ~ genIdentifier();
    immutable string labelLoop = "while_" ~ genIdentifier();
    immutable string srctxt = "while " ~ strip(child.input[child.begin .. child.end]);
    writeln(labelLoop ~ ":");
    emitExpression(child); // result ends up in register 'a'
    writeln("  cp   1\t\t; " ~ srctxt);
    writeln("  jr   nz," ~ labelEnd);
    emitStatementList(node.children[1]);
    writeln("  jp   " ~ labelLoop);
    writeln(labelEnd ~ ":");
}

void emitReturnStatement(ParseTree node) {
    if (node.children.length > 0)
        emitExpression(node.children[0]);
    writeln("  ret");
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
    return Symbol();
}

void emitLiteral(ParseTree node) {
    string literal = node.matches[0];

    switch (node.name) {
    case "Retro8.DecLit":
    case "Retro8.HexLit":
    case "Retro8.BinLit":
    case "Retro8.OctLit":
        writeln("  ld   a,", literal);
        break;
    case "Retro8.BoolLit":
        writeln("  ld   a,", (literal == "true" ? "1" : "0"));
        break;
    case "Retro8.StringLit":
        // string literal found. put it constant list
        string identifier = genIdentifier();
        Symbol symbol = {
            Kind.Constant, identifier, Type.Byte, false, true, true, literal, ""
        };
        symboltable[identifier] = symbol;
        writeln("  ld   bc,", identifier, "\t; ad-hoc string literal");
        break;
    default:
        stderr.writeln("Unknown node: ", node.name);
        break;
    }
}

void emitIdentifier(ParseTree node) {
    // variable or constant (i.e. memory, constant or register)
    Symbol s = getSymbolForIdentifier(node);

    switch (s.kind) {
    case Kind.Constant:
        if (s.indirection)
            writeln("  ld   bc,", s.name, "\t; constant indirection");
        else
            writeln("  ld   a,", s.value, "\t; constant no indirection");
        break;
    case Kind.Variable:
        if (s.indirection)
            writeln("  ld   bc,", s.name, "\t; variable indirection");
        else
            writeln("  ld   a,(", s.name, ")\t; variable no indirection");
        break;
    case Kind.Register:
        writeln("  ld   a,", s.name, "\t; register");
        break;
    default:
        stderr.writeln("Internal compiler error. Unknown symbol");
        break;
    }

}

void emitRegister(ParseTree node) {
    writeln("  ld   a,", node.matches[0].toLower());
}

void emitEvalOperation(ParseTree node) {
    ParseTree op1 = node.children[0];
    ParseTree op2 = node.children[2];

    // check if we have to descend first
    if (op1.name == "Retro8.SimpleExpression" || op1.name == "Retro8.Term"
            || op1.name == "Retro8.Expression") {
        emitExpression(op1);
        //writeln("  ld   c,a\t\t; store result from op1"); // move a to c
        writeln("  push af\t\t; store result from op1");
        emitExpression(op2);
        writeln("  ld   b,a\t\t; swap operands");
        writeln("  pop  af\t\t; fetch stored result");
    }
    else {
        emitExpression(op2);
        writeln("  ld   b,a\t\t; store result 3");
        emitExpression(op1);
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
}

Type emitExpression(ParseTree node) {
    Type type = Type.Byte;
    switch (node.name) {
    case "Retro8.Register":
        emitRegister(node);
        break;
    case "Retro8.Literal":
        emitLiteral(node.children[0]);
        break;
    case "Retro8.Identifier":
        emitIdentifier(node);
        break;
    case "Retro8.IndirectAccess":
        Symbol s = getSymbolForIdentifier(node.children[0]);
        switch (s.kind) {
        case Kind.Constant:
            writeln("  ld   a,(", s.value, ")");
            break;
        case Kind.Register:
            writeln("  ld   a,(", s.name, ")");
            break;
        case Kind.Variable:
            if (!s.indirection)
                stderr.writeln("WARNING: using byte as pointer ", __LINE__);
            writeln("  ld   hl,(", s.name, ")");
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
            emitExpression(node.children[0]);
        else if (node.children.length == 3)
            emitEvalOperation(node);
        break;
    case "Retro8.FuncCall":
        emitFunctionCall(node);
        break;

    default:
        foreach (ParseTree child; node.children)
            emitExpression(child);
        break;
    }
    return type;
}

/*
void emitExpression(ParseTree node) {

    if (node.children.length == 0) {
        // we're at a leaf node (can only be: literal, or identifier)
        Symbol s = getSymbol(node);
        if (node.name == "Retro8.Register") {
            writeln("  ld   a,", getOperand(node));
        }
        else {
                // identifier can be constant or variable
            if (isIndirection(node)) {
                writeln("  ld   hl,", getOperand(node));
            }
            else {
                writeln("  ld   a,", getOperand(node));
            }
        }
    }
    else if (node.children.length == 1) {
        // nothing do do here; descend further
        if (node.name == "Retro8.Literal") {
            if (node.children[0].name == "Retro8.StringLit")
                writeln("  ld   bc, ", getOperand(node.children[0]));
            else
                writeln("  ld   a, ", getOperand(node.children[0]));
        }
        else if (node.name == "Retro8.IndirectAccess") {
            writeln("  ld   a,(", getOperand(node.children[0]), ")");
        }
        else if (node.name == "Retro8.FuncCall") {
            emitFunctionCall(node);
        }
        else {
            emitExpression(node.children[0]);
        }
    }
    else if (node.name == "Retro8.FuncCall") {
        emitFunctionCall(node);
    }
    else if (node.name == "Retro8.Factor") {
        // must have two children or would have been caught above
        // this is an array index identifier
        emitExpression(node.children[0]); // gets base address
        emitExpression(node.children[1]); // gets offset
        writeln("  push bc");
        writeln("  ld   bc,a"); // accu contains offset
        writeln("  add  hl,bc");
        writeln("  ld   a,(hl)");
        writeln("  pop  bc");
    }
    else if (node.name == "Retro8.SimpleExpression"
            || node.name == "Retro8.Term" || node.name == "Retro8.Expression") {
        // nodes have three children, must be an operator
        ParseTree op1 = node.children[0];
        ParseTree op2 = node.children[2];

        // check if we have to descend first
        if (op1.name == "Retro8.SimpleExpression" || op1.name == "Retro8.Term"
                || op1.name == "Retro8.Expression") {
            emitExpression(op1);
            //writeln("  ld   c,a\t\t; store result from op1"); // move a to c
            writeln("  push af\t\t; store result from op1");
            emitExpression(op2);
            writeln("  ld   b,a\t\t; swap operands");
            writeln("  pop  af\t\t; fetch stored result");
        }
        else {
            emitExpression(op2);
            writeln("  ld   b,a\t\t; store result 3");
            emitExpression(op1);
        }

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
    }
}
*/

void emitFunctionCall(ParseTree node) {
    //foreach argument in the list
    if (node.children.length > 1) {
        // get the symbol for this function call
        Symbol s = getSymbolForIdentifier(node.children[0]);
        if (s.kind != Kind.Function) {
            stderr.writeln("** ERROR ** symbol ", node.children[0].matches[0],
                    " is not a function. ", __LINE__);
            exit(1);
        }
        foreach (i, arg; node.children[1].children) {
            Param p = s.funcargs[i];
            emitExpression(arg);
            // TODO: check signature and put the arguments in the correct registers
            // check the type of the expression so we can change a to bc
            writeln("  ld   ", p.register, ",a");
        }
    }
    writeln("  call " ~ node.children[0].matches[0] ~ "\t\t; " ~ strip(
            node.input[node.begin .. node.end]));
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

    // add name to symbol tables
    Symbol symbol = {
        Kind.Variable, "v_" ~ identifier, type, isSigned, indirection, false, "", srctext
    };
    if (node.children.length > 3)
        symbol.value = node.matches[4];
    symboltable[identifier] = symbol;

    // do type checks here
}

void processParamList(ParseTree node, Symbol* s) {
    string register = node.children[0].matches[0];
    Type type = textToType(node.children[1].matches[0]);
    bool isIndirection = node.children[2].name == "Retro8.TypeSuffix";
    string identifier = node.children[isIndirection ? 3 : 2].matches[0];
    bool isSigned = isTypeSigned(node.matches[2]);
    Symbol ls = {
        Kind.Register, "", type, isSigned, isIndirection, false, "", "", register
    };
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
    LocalScope ls;
    localsymbolstack ~= ls;

    Type type = Type.None;
    bool isSigned = false;
    if (node.children.length > 2) {
        type = textToType(node.children[3].matches[0]);
        isSigned = isTypeSigned(node.children[3].matches[0]);
    }
    // add the function to the global symbol table
    Symbol s = {Kind.Function, identifier, type, isSigned, false, false, "", ""};

    if (node.children[1].children.length > 0) {
        processParamList(node.children[1].children[0], &s);
    }
    symboltable[identifier] = s;
    
    writeln(node.matches[0] ~ ":\t\t\t; " ~ strip(node.input[node.begin .. node.end]));
}

void emitFunctionStart(ParseTree node) {
    emitFunctionSignature(node.children[0]);
    // save all registers we're going to use
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
    writeln("            \t\t; " ~ strip(node.input[node.begin .. node.end]));
    emitExpression(node.children[1]);
    // check result of expression
    if (node.children[0].name == "Retro8.RegisterLit") {
        writeln("  ld   " ~ node.children[0].matches[1].toLower() ~ ",a");
    }
    else {
        Symbol s = symboltable[node.children[0].matches[0]];
        writeln("  ld   (", s.name, "),a");
    }
}
