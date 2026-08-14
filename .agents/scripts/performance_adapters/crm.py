from performance_adapters.base import envelope

def normalize(document, **kwargs):
    return envelope(document, "crm", **kwargs)
