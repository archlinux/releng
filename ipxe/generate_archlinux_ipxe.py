#!/usr/bin/env python
import os
import urllib.request
import orjson
import jinja2
from collections import namedtuple
from operator import itemgetter

mirrors_url = "https://archlinux.org/mirrors/status/json"
releases_url = "https://archlinux.org/releng/releases/json/"

def retrieve_releases():
    releases = []
    with urllib.request.urlopen(releases_url) as url:
        data = orjson.loads(url.read())
        releases = sorted(data["releases"], key=itemgetter('release_date'), reverse=True)
        releases = [ release["version"] for release in releases if release["available"]]

    return releases
    
    
def retrieve_mirrors():
    mirrorurls = []
    with urllib.request.urlopen(mirrors_url) as url:
        data = orjson.loads(url.read())

        for mirror in data["urls"]: 
            if mirror["protocol"] == "http" and mirror["active"] and mirror["isos"]:
                keys = ["url", "name", "country_code", "country"]
                mirrorObj = namedtuple("Mirror", keys)
                mirror = mirrorObj(mirror["url"], mirror["details"].rsplit('/',3)[1], mirror["country_code"], mirror["country"])
                mirrorurls.append(mirror)

        mirrorurls = sorted(mirrorurls, key=lambda x: x.name)
        mirrorurls = sorted(mirrorurls, key=lambda x: x.country)
    
    return mirrorurls

def sort_mirrors_by_country(mirrorurls):
    mirrors_by_country = {}
    for mirror in mirrorurls:
        if mirror.country_code not in mirrors_by_country.keys():
            mirrors_by_country[mirror.country_code] = {"grouper": mirror.country_code, "grouper_name": mirror.country, "list": []} 
        
        mirrors_by_country[mirror.country_code]["list"].append({"url": mirror.url, "name": mirror.name})

    mirrors_by_country = mirrors_by_country.values()

    return mirrors_by_country

def render_from_jinja_template(mirrors_by_country, releases):
    dir_path = os.path.dirname(os.path.realpath(__file__))
    archlinux_ipxe_template = "archlinux.ipxe.jinja"

    templateLoader = jinja2.FileSystemLoader(dir_path)
    templateEnv = jinja2.Environment(loader=templateLoader)
    template = templateEnv.get_template(archlinux_ipxe_template)

    print((template.render(mirrors_by_country = mirrors_by_country, releases = releases)))
   

def main():
    releases = retrieve_releases()
    mirrorurls = retrieve_mirrors()
    mirrors_by_country = sort_mirrors_by_country(mirrorurls)

    render_from_jinja_template(mirrors_by_country, releases)


if __name__ == "__main__":
    main()
