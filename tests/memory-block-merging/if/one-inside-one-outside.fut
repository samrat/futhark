-- An if expression where one branch array is defined outside the 'if', and one
-- is defined inside the 'if'.  This should be okay as long as the usual safety
-- conditions are kept, since 'ys0' and 'ys1' can use the same memory block
-- without 'ys0' being overwritten (it seems).
-- ==
-- input { [[1, 4], [9, 16]]
--         false
--         1
--       }
-- output { [[1, 4], [1, 2]]
--        }
-- structure cpu { Alloc 2 }

-- This should hopefully end up as 'structure cpu { Alloc 0 }' when we extend
-- the optimisation.

let main (xs: *[#n][#n]i32, cond: bool, i: i32): [n][n]i32 =
  let ys0 = iota n
  let ys = if cond
           then ys0
           else let ys1 = map (+ 1) (iota n)
                in ys1
  let xs[i] = ys
  in xs
