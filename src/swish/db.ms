;;; Copyright 2017 Beckman Coulter, Inc.
;;;
;;; Permission is hereby granted, free of charge, to any person
;;; obtaining a copy of this software and associated documentation
;;; files (the "Software"), to deal in the Software without
;;; restriction, including without limitation the rights to use, copy,
;;; modify, merge, publish, distribute, sublicense, and/or sell copies
;;; of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be
;;; included in all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
;;; HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
;;; WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
;;; DEALINGS IN THE SOFTWARE.

(import
 (swish app-io)
 (swish db)
 (swish erlang)
 (swish io)
 (swish mat)
 (swish osi)
 (swish testing)
 (except (chezscheme) define-record exit sleep))

(define filename (path-combine data-dir "test-db.db3"))

(define-syntax assert-syntax-error
  (syntax-rules ()
    [(_ e expected) ($assert-syntax-error 'e expected)]))

(define ($assert-syntax-error e expected)
  (guard
   (x
    [(and (syntax-violation? x) (string=? (condition-message x) expected))
     'ok])
   (eval e)
   (errorf 'assert-syntax-error "failed to raise syntax error: ~s" e)))

(define-syntax (echo-sql x)
  (syntax-case x ()
    [(k sql)
     (let-values ([(query args) (parse-sql #'sql)])
       (with-syntax ([query (datum->syntax-object #'k query)]
                     [(arg ...) args])
         #'(list query arg ...)))]))

(define (make-integers max-bits)
  (define (ones i ls)
    (if (< i max-bits)
        (ones (+ i 1)
          (let ([x (bitwise-arithmetic-shift 1 i)])
            (cons* x (bitwise-not x) ls)))
        ls))
  (define (twos i j ls)
    (if (< i max-bits)
        (if (< j i)
            (let ([x (bitwise-ior
                      (bitwise-arithmetic-shift 1 i)
                      (bitwise-arithmetic-shift 1 j))])
              (cons* x (bitwise-not x) ls))
            (twos (+ i 1) 0 ls))
        ls))
  (twos 1 0 (ones 0 '(0 -1))))

(define (make-doubles)
  (define B 10)
  (define P 18)
  (define emin -306)
  (define emax 308)

  (define (type1 i x y ls)
    (if (> i P)
        ls
        (type1 (+ i 1) x (/ y B) (cons (+ x y) ls))))

  (define (type2 i x y ls)
    (if (> i P)
        ls
        (let ([x (+ x y)] [y (/ y B)])
          (type2 (+ i 1) x y (cons x ls)))))

  (define (type4 ls)
    (fold-left (lambda (ls x) (cons (* (- B 1) x) ls)) ls ls))

  (define (shift e fractions ls)
    (if (> e emax)
        ls
        (shift (+ e 1) fractions
          (fold-left (let ([s (expt B e)])
                       (lambda (ls x) (cons (exact->inexact (* x s)) ls)))
            ls fractions))))

  (define (remdup ls)
    (if (null? ls)
        '()
        (let loop ([x (car ls)] [ls (cdr ls)] [acc '()])
          (if (null? ls)
              (cons x acc)
              (let ([y (car ls)])
                (if (eqv? x y)
                    (loop x (cdr ls) acc)
                    (loop y (cdr ls) (cons x acc))))))))

  (let ([positives
         (remdup
          (sort fl>
            (shift emin
              (type4 (type2 1 0 (/ B) (type1 3 (/ B) (expt B -3) '())))
              '(0.0))))])
    (fold-left (lambda (ls x) (cons (fl- x) ls))
      positives positives)))

(define (make-strings)
  (define next-char
    (let ([seed 3])
      (lambda ()
        (let ([x (modulo (+ seed 43) #x110000)])
          (set! seed x)
          (if (<= #xD800 x #xDFFF)
              (next-char)
              (integer->char x))))))
  (define (populate s i)
    (when (< i (string-length s))
      (string-set! s i (next-char))
      (populate s (+ i 1))))
  (let loop ([n 1493] [ls '()])
    (if (< n 0)
        ls
        (let ([s (make-string n)])
          (populate s 0)
          (loop (- n 1) (cons s ls))))))

(define (make-blobs)
  (define next-u8
    (let ([seed 3])
      (lambda ()
        (let ([x (modulo (+ seed 43) 256)])
          (set! seed x)
          x))))
  (define (populate bv i)
    (when (< i (bytevector-length bv))
      (bytevector-u8-set! bv i (next-u8))
      (populate bv (+ i 1))))
  (let loop ([n 256] [ls '()])
    (if (< n 0)
        ls
        (let ([bv (make-bytevector n)])
          (populate bv 0)
          (loop (- n 1) (cons bv ls))))))

(print-unicode #f)

(isolate-mat marshal ()
  (define goodies
    (append '(#f) (make-integers 63) (make-doubles) (make-strings)
      (make-blobs)))
  (catch (remove-file filename))
  (match-let* ([#(ok ,db) (db:start&link #f filename 'create)])
    (transaction db
      (execute "create table data(x)")
      (for-each (lambda (x) (execute "insert into data(x) values(?)" x))
        goodies))
    (transaction db
      (define (check x result)
        (match result
          [(#(,@x)) 'ok]
          [,_ (errorf 'check "~s didn't match: ~s\n" x result)]))
      (fold-left
       (lambda (id x)
         (check x (execute "select x from data where rowid=?" id))
         (+ id 1))
       1 goodies))
    (db:stop db)
    (catch (remove-file filename))))

(isolate-mat m1 ()
  (catch (remove-file filename))
  (match-let*
   ([#(ok ,db) (db:start&link #f filename 'create)]
    [,@filename (db:filename db)]
    [created-tables
     (transaction db
       (execute "CREATE TABLE table1 (col1, col2, col3)")
       (execute "CREATE TABLE table2 (col1, col2, col3)")
       (execute "CREATE TABLE table3 (col1, col2, col3)")
       'created-tables)])
   ;; Test that the rollback statement gets reset; otherwise, the drop
   ;; table statement will get a table locked error.
   (match-let*
    ([#(error boom)
      (db:transaction db
        (lambda ()
          (execute "create table temp.foo(x)")
          (exit 'boom)))])
    (transaction db (execute "create table temp.foo(x)"))
    (transaction db (execute "drop table temp.foo")))
   (do ([i 0 (+ i 1)]) ((= i 150))
     (db:log db "INSERT INTO table1 (col1, col2, col3) VALUES(?,?,?)"
       i i i))
   (receive (after 1000 (void)))
   (do ([i 0 (+ i 1)]) ((= i 150))
     (db:log db "INSERT INTO table2 (col1, col2, col3) VALUES(?,?,?)"
       i i i))
   (match-let*
    ([inserted-rows
      (transaction db
        (do ([i 0 (+ i 1)]) ((= i 150))
          (execute "INSERT INTO table3 (col1, col2, col3) VALUES(?,?,?)"
            i i i))
        'inserted-rows)]
     [selected-rows-lazy
      (transaction db
        (let ([thunk (lazy-execute "SELECT col1 FROM table1")])
          (do ([i 0 (+ i 1)]) ((= i 10))
            (assert (thunk))))
        'selected-rows-lazy)]
     [#("col1" "col2" "Column3")
      (transaction db
        (columns "SELECT col1,col2,col3 AS Column3 FROM table1"))]
     [#(EXIT failed-transaction)
      (catch (transaction db (exit 'failed-transaction)))])
    (db:stop db)
    (catch (remove-file filename)))))

(mat errors ()
  (match-let*
   ([#(EXIT #(invalid-context lazy-execute)) (catch (lazy-execute "SELECT 1"))]
    [#(EXIT #(invalid-context execute)) (catch (execute "SELECT 1"))]
    [#(EXIT #(invalid-context columns)) (catch (columns "SELECT 1"))])
   'ok))

(mat expand-sql ()
  (match-let*
   ([("insert into table1(col1, col2, col3) values(?, ?, ?)" 1 1 1)
     (let ([i 1])
       (echo-sql (insert table1 ([col1 ,i] [col2 ,i] [col3 ,i]))))]
    [("update table1 set col1=1 where rowid = 1")
     (echo-sql (update table1 ([col1 "1"]) where rowid = "1"))]
    [("update table1 set col1=1, col2=1 where rowid = 1")
     (echo-sql (update table1 ([col1 "1"] [col2 "1"]) where rowid = "1"))]
    [("update table1 set col1=?, col2=? where id = ?" 1 2 3)
     (let ([col1 1] [col2 2] [id 3])
       (echo-sql (update table1 ([col1 ,col1] [col2 ,col2]) where id = ,id)))]
    [("delete from table1")
     (echo-sql (delete table1))]
    [("delete from table1 where id > 10")
     (echo-sql (delete table1 where id > "10"))])
   (assert-syntax-error
    (echo-sql (insert table1 ([col1 1])))
    "invalid SQL term")
   (assert-syntax-error
    (echo-sql (update table1 ([col1 1]) where rowid = "1"))
    "invalid SQL term")
   (assert-syntax-error
    (echo-sql (delete table1 where rowid = 1))
    "invalid SQL term")
   'ok))

(isolate-mat db-guardian ()
  (let ([g (make-guardian)])
    (g (sqlite:open filename (+ SQLITE_OPEN_READWRITE SQLITE_OPEN_CREATE)))
    (gc)
    (assert (handle-gone? (g))))
  (catch (remove-file filename)))
