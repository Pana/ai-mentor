// Column arithmetic for the 竖式 element: digits by column (0 = ones), carries and borrows.
// The page computes the result itself, so a written calculation is never wrong even if the model is.

export const digits = n => String(Math.abs(n)).length;
export const digit = (n, column) => Math.floor(Math.abs(n) / 10 ** column) % 10;
/** The digit shown in a column, or null left of the number's first digit. */
export const shown = (n, column) => (column < digits(n) ? digit(n, column) : null);

/**
 * `carries[c]` is the carry written into column c (from the column on its right), for + and ×.
 * `borrows` holds the columns of `a` that lent 1 to the column on their right, for −.
 */
export function columnCalc(a, b, operator) {
  const carries = {}, borrows = new Set();
  let result;
  if (operator === '-') {
    result = a - b;
    let borrow = 0;
    for (let column = 0; column < digits(a); column++) {
      borrow = digit(a, column) - borrow < digit(b, column) ? 1 : 0;
      if (borrow) borrows.add(column + 1);
    }
  } else if (operator === '×') {
    result = a * b;
    let carry = 0;
    for (let column = 0; column < digits(a); column++) {
      carry = Math.floor((digit(a, column) * b + carry) / 10);
      if (carry) carries[column + 1] = carry;
    }
  } else {
    result = a + b;
    let carry = 0;
    for (let column = 0; column < Math.max(digits(a), digits(b)); column++) {
      carry = Math.floor((digit(a, column) + digit(b, column) + carry) / 10);
      if (carry) carries[column + 1] = carry;
    }
  }
  return { a, b, operator, result, carries, borrows, width: Math.max(digits(a), digits(b), digits(result)) };
}
