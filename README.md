# expr2

A JIT-compiled RPN calculator. This is just as stupid as [last time][expr].

[expr]: https://github.com/vktec/expr

## Usage

```
expr2 [EXPRESSION]
```

An expression can be provided as the first command line argument, otherwise expressions will be read line-by-line from stdin.

Supported operators are `+`, `-`, `*` and `/`.
Numbers can be in decimal (no prefix), binary (prefix with `0b`), octal (prefix with `0o`) or hexadecimal (prefix with `0x`).
