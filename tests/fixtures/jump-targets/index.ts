export function plain(xs: number[]) {
    break;
    continue;
    outer: for (const x of xs) {
        inner: while (x > 0) {
            if (x === 1) continue outer;
            if (x === 2) break inner;
            break missing;
        }
        block: {
            if (x === 3) break block;
            continue block;
        }
    }
    switch (xs.length) {
        case 0:
            break;
        case 1:
            continue;
    }
}

export function crossing(xs: number[]) {
    for (const x of xs) {
        xs.forEach(() => {
            if (x) break;
            continue;
        });
        const f = function () {
            break;
        };
        f();
    }
    loop: for (;;) {
        class C {
            static {
                break loop;
            }
            m() {
                continue loop;
            }
        }
        new C().m();
    }
}

export function labels() {
    a: {
        b: {
            a: for (;;) {
                break a;
            }
        }
    }
    c: {
        const g = () => {
            c: for (;;) break c;
        };
        g();
    }
}
