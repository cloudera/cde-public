from pyzipcode import ZipCodeDatabase
import datetime

def tzOffsetFromZip(zipCode):
    zcdb = ZipCodeDatabase()
    offset = None

    try:
        zipcode = zcdb[zipCode]
        offset = zipcode.timezone
    except:
        pass

    return offset
