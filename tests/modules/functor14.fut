-- Deep multiple applications of a parametric module must work.
--
-- ==
-- input { 1 } output { 129 }

module type mt = {
  val f: i32 -> i32
}

module pm1(R: mt): {val g1:i32->i32} = {
  fun h(x: i32): i32 = R.f (R.f x)
  fun g1(x: i32): i32 = h x
}

module pm2(R: mt) = {
  open pm1(R)
  fun g2(x: i32): i32 = g1 (g1 x)
}

module pm3(R: mt) = {
  open pm2(R)
  fun g3(x: i32): i32 = g2 (g2 x)
}

module pm4(R: {val f:i32->i32}) = {
  open pm3(R)
  fun g4(x: i32): i32 = g3 (g3 x)
}

module pm5(R: mt) = {
  open pm4(R)
  fun g5(x: i32): i32 = g4 (g4 x)
}

module pm6(R: mt) = {
  open pm5(R)
  fun g6(x: i32): i32 = g5 (g5 x)
}

module m1 = { fun f (x: i32) = x + 1 }

module m2 = pm6(m1)
module m3 = pm6(m1)

fun main(x: i32) = m2.g6 (m3.g6 x)
