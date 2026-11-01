interface NumList { kind: 'n'; [x: number]: number }
interface StrList { kind: 's'; [x: number]: string }
function foo<T extends NumList | StrList>(arr: T & (NumList | StrList)) {
  const zz = arr[1];
  const q: boolean = zz;
}
