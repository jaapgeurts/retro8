import std.stdio;
import std.file;
import std.string;
import std.conv;
import std.variant;
import std.random : uniform;
import std.range;
import std.algorithm;
import std.algorithm.searching : count;

import pegged.grammar;

mixin(grammar(`
Retro8:
    Start        <  Unit Import* Sequence Eof
    Unit         <  "unit" Identifier ';'?
    Import       <  "import" Identifier ';'?

    Identifier   <~ [a-zA-Z_]([a-zA-Z_]/[0-9])*

    Sequence     <  ConstList? VarList? ExternList? Function*

    ConstList    <  "constants" '{' ConstDecl* '}'
    ConstDecl    <  Identifier '=' Literal ';'?

    VarList      <  "variables" Comment* '{'  Comment* VarDecl* '}'
    VarDecl      <  SimpleDecl Comment* ';'?  Comment*
    #              / arraydecl ';'?

    ExternList   < "extern" Comment* '{' Comment* Prototype* '}'

    SimpleDecl   <  Identifier ':' Type (':=' Literal)?
    Type         <-  "uint8"
                  / "int8"
                  / "uint16"
                  / "int16"
                  / "char"
                  / "bool"
                  / "string"

    Literal      <- DecLit / BinLit / OctLit / HexLit / BoolLit / StringLit
    DecLit       <~ [0-9]+
    BinLit       <~ '0b' [0-1]+
    OctLit       <~ '0o' [0-7]+
    HexLit       <~ '0x' ([0-9A-F][0-9A-F])+
    BoolLit      <- "true" / "false" 
    StringLit    <- :doublequote ~((!(doublequote / eol)  .)*) :doublequote

    Function     <  "function" Comment* Signature Comment* StatementBlock
    Prototype    <  "function" Comment* ProtoSignature

    Signature    <  Identifier Parameters (':' Type )?
    Parameters   < '(' ParamList? ')'
    ParamList    <  Type Identifier (',' ParamList )?

    ProtoSignature    <  Identifier ProtoParameters (':' Type )?
    ProtoParameters   < '(' ParamTypeList? ')'
    ParamTypeList     <  Type Identifier? (',' ProtoParameters )?

    StatementBlock < '{' Comment* StatementList* '}' 
    StatementList  < Statement Comment* ';'? Comment* (StatementList)*

    Statement       <  AssignmentStmt 
                     / ReturnStmt
                     / IfStmt
                     / WhileStmt
                     / FuncCall

    AssignmentStmt   <  Identifier ':=' Expression
    ReturnStmt       < "return" Expression
 
    IfStmt           < "if" Expression StatementBlock ("else" StatementBlock)?
    WhileStmt        < "while" Expression StatementBlock

    Expression    <  SimpleExpression (RelationOp SimpleExpression)?
    SimpleExpression <  ( '+' / '-' )? Term (AddOp Term)*
    Term          <  Factor (MulOp Factor)*

    Factor        <  Literal
                    / Identifier
                    / '(' Expression ')'
                    / "null"
                    / FuncCall

    ExprList      <  Expression (',' Expression)*

    RelationOp    <  '<=' / '>=' / '!=' / '=' / '<' / '>' 
    AddOp         <   "or" / '+' / '-'
    MulOp         <  '%' / '*' / '/' / "and"
                
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

enum Kind {
    None,
    Constant,
    Variable,
    Function
}

struct Symbol {
    Kind kind = Kind.None;
    string identifier;
    string type; // uint8, int8, uint16, int16, char, string, bool, func, pointers & arrays
    string value;
    string code;
}

Symbol[string] symboltable;

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
    foreach (v; symboltable) {
        if (v.kind == Kind.Variable || (v.kind == Kind.Constant && v.type == "string")) {
            switch (v.type) {
            case "uint8":
            case "int8":
                if (v.identifier.length >= 8)
                    writeln(v.identifier ~ ":\t.byte " ~ v.value ~ "\t\t; " ~ v.code);
                else
                    writeln(v.identifier ~ ":\t\t.byte " ~ v.value ~ "\t\t; " ~ v.code);
                break;
            case "string":
                if (v.identifier.length >= 8)
                    writeln(v.identifier ~ ":\t.ascii " ~ to!string(
                            v.value.length - v.value.count('\\') ) ~ ",\"" ~ v.value ~ "\"\t\t; " ~ v.code);
                else
                    writeln(v.identifier ~ ":\t\t.ascii " ~ to!string(
                            v.value.length - v.value.count('\\')) ~ ",\"" ~ v.value ~ "\"\t\t; " ~ v.code);
                break;
            default:
                writeln("Unknown type: ", v);
                break;
            }
        }
    }
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
                Symbol symbol = {
                    Kind.Constant, identifier, "int8", node.children[1].matches[0], srctext
                };
                symboltable[identifier] = symbol;
                break;
            case "Retro8.StringLit":
                Symbol symbol = {
                    Kind.Constant, identifier, "string", node.children[1].matches[0], srctext
                };
                symboltable[identifier] = symbol;
                break;
            default:
                break;
            }
            break;
        case "Retro8.ProtoSignature":
            string ident = node.matches[0];
            Symbol s = {Kind.Function, ident, "", "", ""};
            symboltable[ident] = s;
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
    if (node.children[1].name != "Retro8.StatementList")
        emitStatement(node.children[1]);
    else
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
    if (node.children[1].name != "Retro8.StatementList")
        emitStatement(node.children[1]);
    else
        emitStatementList(node.children[1]);
    writeln("  jp   " ~ labelLoop);
    writeln(labelEnd ~ ":");
}

void emitOperand(ParseTree node) {
    string identlit = node.matches[0];
    switch (node.name) {
    case "Retro8.Identifier":
        // variable or constant
        if (identlit !in symboltable) {
            stderr.writeln("Unknown identifier near: " ~ node.input[node.begin .. node.end]);
        }
        else {
            Symbol s = symboltable[identlit];
            if (s.kind == Kind.Constant) {
                if (s.type == "string")
                    writeln("  ld   a," ~ s.identifier);
                else
                    writeln("  ld   a," ~ s.value);
            }
            else if (s.kind == Kind.Variable) {
                if (s.type == "string")
                    writeln("  ld   a," ~ identlit);
                else
                    writeln("  ld   a,(" ~ identlit ~ ")");
            }
        }
        break;
    case "Retro8.DecLit":
        writeln("  ld   a," ~ identlit);
        break;
    case "Retro8.HexLit":
        writeln("  ld   a," ~ identlit);
        break;
    case "Retro8.BoolLit":
        writeln("  ld   a," ~ (identlit == "true" ? "1" : "0"));
        break;
    case "Retro8.BinLit":
        writeln("  ld   a," ~ identlit);
        break;
    case "Retro8.OctLit":
        writeln("  ld   a," ~ identlit);
        break;
    case "Retro8.StringLit":
        // string literal found. put it constant list
        string identifier = genIdentifier();
        Symbol symbol = {Kind.Constant, identifier, "string", identlit, ""};
        symboltable[identifier] = symbol;
        writeln("  ld   hl," ~ identifier);
        break;
    default:
        stderr.writeln("Unknown node: ", node.name);
        stderr.writeln("String literals not supported in expression: ",
                node.input[node.begin .. node.end]);
        break;
    }
}

void emitExpression(ParseTree node) {

    if (node.children.length == 0) {
        // we're at a leaf node (can only be: literal, or identifier)
        emitOperand(node);
    }
    else if (node.children.length == 1) {
        // nothing do do here; descend further
        emitExpression(node.children[0]);
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
            writeln("  ld   c,a\t\t; store result from op1"); // move a to c
            emitExpression(op2);
            writeln("  ld   b,a\t\t; swap operands");
            writeln("  ld   a,c");
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
            string lblFalse = genIdentifier();
            switch (node.children[1].matches[0]) {
            case "=":
                writeln("  jr   nz," ~ lblFalse);
                break;
            case "!=":
                writeln("  jr   z," ~ lblFalse);
                break;
            case "<":
                writeln("  jr   nc," ~ lblFalse);
                break;
            case ">":
                writeln("  jr   c," ~ lblFalse);
                break;
            case "<=":
                writeln("  jr   c," ~ lblFalse);
                writeln("  jr   nz," ~ lblFalse);
                break;
            case ">=":
                writeln("  jr   nc," ~ lblFalse);
                writeln("  jr   nz," ~ lblFalse);
                break;
            default:
                break;
            }
            string lblEndIf = genIdentifier();
            writeln("  ld   a,1\t\t; true");
            writeln("  jr   " ~ lblEndIf);
            writeln(lblFalse ~ ":");
            writeln("  ld   a,0\t\t; false");
            writeln(lblEndIf ~ ":");
            break;
        default:
            break;
        }

        return;
    }
}

void emitFunctionCall(ParseTree node) {
    //foreach argument in the list
    if (node.children.length > 1) {
        foreach (arg; node.children[1].children) {
            emitExpression(arg);
        }
    }
    writeln("  call " ~ node.children[0].matches[0] ~ "\t\t; " ~ strip(
            node.input[node.begin .. node.end]));
}

void emitSimpleDecl(ParseTree node) {
    string srctext = strip(node.input[node.begin .. node.end]);
    immutable string type = node.matches[2];
    string identifier = node.matches[0];
    // add name to symbol tables

    Symbol symbol = {Kind.Variable, identifier, type, "", srctext};
    if (node.matches.length > 3)
        symbol.value = node.matches[4];
    symboltable[identifier] = symbol;

    // do type checks here
}

void emitFunctionSignature(ParseTree node) {
    writeln(node.matches[0] ~ ":\t\t\t; " ~ strip(node.input[node.begin .. node.end]));
}

void emitFunctionStart(ParseTree node) {
    //    writeln("  push ix\t; enter");
    //    writeln("  ld   ix, sp\t; ");
    emitFunctionSignature(node.children[0]);
}

void emitFunctionEnd(ParseTree node) {
    //    writeln("  ld   sp,ix\t; leave");
    //    writeln("  pop  sp\t;");
    writeln("  ret");
}

void emitAssignmentStmt(ParseTree node) {
    writeln("            \t\t; " ~ strip(node.input[node.begin .. node.end]));
    emitExpression(node.children[1]);
    writeln("  ld   hl, " ~ node.children[0].matches[0]);
    writeln("  ld   (hl), a");
}
