from performance_adapters.base import envelope

def normalize(document, **kwargs):
    source_class = "payment" if isinstance(document, dict) and document.get("source", {}).get("source_class") == "payment" else "commerce"
    return envelope(document, source_class, **kwargs)
