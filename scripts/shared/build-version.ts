export function version(value: string) {
    if (!/^[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}$/.test(value)) {
        throw new Error(`Invalid Apple build number: ${JSON.stringify(value)}`);
    }
    const parts = value.split(".").map(Number);
    while (parts.length < 3) parts.push(0);
    return parts;
}
