const sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle";

class Element {
    readonly namespaces: Record<string, string>;
    constructor(readonly node: Bun.XML.Node, inherited: Record<string, string> = {}) {
        this.namespaces = { ...inherited };
        for (const [name, value] of Object.entries(node.attributes)) {
            if (name === "xmlns") this.namespaces[""] = value;
            else if (name.startsWith("xmlns:")) this.namespaces[name.slice(6)] = value;
        }
    }
    private matches(qualified: string, local: string, namespace: string, attribute = false) {
        const colon = qualified.indexOf(":");
        const name = colon < 0 ? qualified : qualified.slice(colon + 1);
        const prefix = colon < 0 ? "" : qualified.slice(0, colon);
        const uri = attribute && !prefix ? "" : this.namespaces[prefix] || "";
        return name === local && uri === namespace;
    }
    children(name: string, namespace = "") {
        return this.node.children.filter((child): child is Bun.XML.Node =>
            typeof child !== "string" && "name" in child)
            .map(node => new Element(node, this.namespaces))
            .filter(element => element.matches(element.node.name, name, namespace));
    }
    child(name: string, namespace = "") { return this.children(name, namespace)[0]; }
    attribute(name: string, namespace = "") {
        return Object.entries(this.node.attributes)
            .find(([key]) => this.matches(key, name, namespace, true))?.[1];
    }
    text() { return this.node.children.filter(child => typeof child === "string").join(""); }
    sparkle(name: string) { return this.child(name, sparkleNamespace)?.text(); }
    sparkleAttribute(name: string) { return this.attribute(name, sparkleNamespace); }
}

export function appcastItems(xml: string) {
    const root = new Element(Bun.XML.parse(xml, { compact: false }));
    if (root.node.name !== "rss") throw new Error("The appcast root must be rss.");
    return root.child("channel")?.children("item") ?? [];
}
