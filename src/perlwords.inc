const
  KeywordList : array[0..50] of TWordStr = (
    'BEGIN', 'CHECK', 'END', 'INIT', 'UNITCHECK', '__DATA__', '__END__',
    '__FILE__', '__LINE__', '__PACKAGE__', '__SUB__', 'and', 'cmp',
    'continue', 'default', 'do', 'else', 'elsif', 'eq', 'for', 'foreach',
    'ge', 'given', 'goto', 'gt', 'if', 'isa', 'last', 'le', 'local', 'lt',
    'my', 'ne', 'next', 'no', 'not', 'or', 'our', 'package', 'redo',
    'require', 'return', 'state', 'sub', 'unless', 'until', 'use', 'when',
    'while', 'x', 'xor');

  BuiltinList : array[0..188] of TWordStr = (
    'abs', 'accept', 'alarm', 'atan2', 'bind', 'binmode', 'bless', 'caller',
    'chdir', 'chmod', 'chomp', 'chop', 'chown', 'chr', 'chroot', 'close',
    'closedir', 'connect', 'cos', 'crypt', 'dbmclose', 'dbmopen', 'defined',
    'delete', 'die', 'each', 'endgrent', 'endhostent', 'endnetent',
    'endprotoent', 'endpwent', 'endservent', 'eof', 'eval', 'exec',
    'exists', 'exit', 'exp', 'fc', 'fcntl', 'fileno', 'flock', 'fork',
    'format', 'formline', 'getc', 'getgrent', 'getgrgid', 'getgrnam',
    'gethostbyaddr', 'gethostbyname', 'gethostent', 'getlogin',
    'getnetbyaddr', 'getnetbyname', 'getnetent', 'getpeername', 'getpgrp',
    'getppid', 'getpriority', 'getprotobyname', 'getprotobynumber',
    'getprotoent', 'getpwent', 'getpwnam', 'getpwuid', 'getservbyname',
    'getservbyport', 'getservent', 'getsockname', 'getsockopt', 'glob',
    'gmtime', 'grep', 'hex', 'index', 'int', 'ioctl', 'join', 'keys',
    'kill', 'lc', 'lcfirst', 'length', 'link', 'listen', 'localtime', 'log',
    'lstat', 'map', 'mkdir', 'msgctl', 'msgget', 'msgrcv', 'msgsnd', 'oct',
    'open', 'opendir', 'ord', 'pack', 'pipe', 'pop', 'pos', 'print',
    'printf', 'prototype', 'push', 'quotemeta', 'rand', 'read', 'readdir',
    'readline', 'readlink', 'readpipe', 'recv', 'ref', 'rename', 'reset',
    'reverse', 'rewinddir', 'rindex', 'rmdir', 'say', 'scalar', 'seek',
    'seekdir', 'select', 'semctl', 'semget', 'semop', 'send', 'setgrent',
    'sethostent', 'setnetent', 'setpgrp', 'setpriority', 'setprotoent',
    'setpwent', 'setservent', 'setsockopt', 'shift', 'shmctl', 'shmget',
    'shmread', 'shmwrite', 'shutdown', 'sin', 'sleep', 'socket',
    'socketpair', 'sort', 'splice', 'split', 'sprintf', 'sqrt', 'srand',
    'stat', 'study', 'substr', 'symlink', 'syscall', 'sysopen', 'sysread',
    'sysseek', 'system', 'syswrite', 'tell', 'telldir', 'tie', 'tied',
    'time', 'times', 'truncate', 'uc', 'ucfirst', 'umask', 'undef',
    'unlink', 'unpack', 'unshift', 'untie', 'utime', 'values', 'vec',
    'wait', 'waitpid', 'wantarray', 'warn', 'write');

  PragmaList : array[0..35] of TWordStr = (
    'attributes', 'autodie', 'autouse', 'base', 'bigint', 'bignum',
    'bigrat', 'bytes', 'charnames', 'constant', 'diagnostics', 'encoding',
    'experimental', 'feature', 'fields', 'filetest', 'if', 'integer',
    'less', 'lib', 'locale', 'mro', 'open', 'overload', 'overloading',
    'parent', 're', 'sigtrap', 'sort', 'strict', 'subs', 'threads', 'utf8',
    'vars', 'version', 'warnings');
