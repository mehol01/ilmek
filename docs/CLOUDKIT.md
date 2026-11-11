# CloudKit kurulumu (gruplar)

Container: `iCloud.com.mehol01.Ilmek` · Public database

Record type'lar app ilk kayıt yaptığında **Development** ortamında otomatik oluşur.
Index'ler otomatik oluşmaz, Console'dan bir kez eklenir.

## 1. Index'leri ekle (Development)

https://icloud.developer.apple.com → İlmek container → **Development** → Schema → Indexes

| Record type | Field | Index |
|---|---|---|
| Membership | groupCode | QUERYABLE |
| Membership | userID | QUERYABLE |
| Membership | recordName | QUERYABLE |
| DayComplete | userID | QUERYABLE |
| DayComplete | recordName | QUERYABLE |

Record type görünmüyorsa: app'te bir grup kur (Group/Membership/Status/DayComplete oluşur), sonra tekrar bak.
DayComplete ilk kez bir günü tamamen bitirince oluşur.

## 2. Production'a gönder (App Store'dan önce ŞART)

Schema → **Deploy Schema Changes…** → Production. Yapılmazsa TestFlight/App Store sürümünde gruplar çalışmaz.

## Güvenlik modeli

Public DB varsayılanı: herkes okur, sadece kaydı oluşturan yazar.
- Kimse başkasının Status / Membership kaydını değiştiremez.
- Group'u sadece kurucu düzenler (ad, limit, çıkarılanlar listesi).
- Gizli alışkanlıkların adı hiç yüklenmez; sadece toplam sayı.
- Atkı sadece "Atkımı arkadaşlarım görsün" açıksa yüklenir.
