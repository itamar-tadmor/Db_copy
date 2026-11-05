# הקמת עותק חלקי של מסד Oracle בעזרת RMAN

מסד יצור בגודל 80TB, סביבה נמוכה עם partitions של השנתיים האחרונות בלבד, וטבלאות ללא partitions במלואן.

> **סטטוס:** הקוד לא הורץ. בסביבת הכתיבה אין Oracle, כך שאפילו הקומפילציה לא נבדקה. אין להריץ ביצור לפני התקנה בסביבת בדיקה ולפני שער 0 (POC).
> **הנחות:** Oracle 19c, Enterprise Edition עם Partitioning, ו-tablespaces של שמות עד 30 תווים. לא נבדקו RAC, Data Guard, Multitenant או Exadata. אם הם קיימים אצלך, יש לעבור על הסעיפים הרלוונטיים לפני הביצוע.

## שלוש מסקנות שעיצבו את הפתרון

### 1. טבלה מחולקת שנחתכת בזמן אינה self-contained לפי Oracle, וזה צפוי

ברגע שה-partitions החדשים משוחזרים והישנים לא, הטבלה חוצה את הגבול. לכן `DBMS_TTS.TRANSPORT_SET_CHECK` ידווח עליה כ-partially contained. הודעות אלה לא יעלמו גם אחרי כל ההזזות.

לכן הפתרון משתמש בהגדרה מעשית. סט ה-tablespaces שאינם משוחזרים תקין כאשר:

| כלל | משמעות |
|---|---|
| R1 | שום דבר שחייב להתקיים ביעד לא נמצא ב-tablespace שמדלגים עליו |
| R2 | כל מה שנמצא ב-tablespace שמדלגים עליו שייך ל-partition היסטורי |
| R3 | כל הסגמנטים של partition היסטורי (טבלה, אינדקס מקומי, LOB) באותו צד |

### 2. `DUPLICATE ... SKIP TABLESPACE` אינו מתאים, נדרש שחזור חלקי ידני

`DUPLICATE` מול מסד המקור מריץ בדיקת transport set ונכשל ב-RMAN-05548 כשהסט אינו עצמאי. לכן התכן משתמש ב:

```
RESTORE DATABASE SKIP TABLESPACE ...
RECOVER DATABASE SKIP FOREVER TABLESPACE ...
```

### 3. הסיכון המרכזי הוא הניקוי ביעד, לא ההזזה ביצור

אחרי פתיחת המסד, ה-partitions ההיסטוריים עדיין במילון הנתונים, ו-Oracle חוסם את הדרכים הישירות:

| פעולה | תוצאה |
|---|---|
| `DROP TABLESPACE` | ORA-14404, כי לטבלה יש partitions גם ב-tablespace אחר |
| `DROP PARTITION` כשלטבלה יש אינדקס כלשהו | ORA-14117 / ORA-14630 |
| טבלה עם LOB | ה-LOB index הפנימי חוסם, ואי אפשר להסיר אותו |

המסלול המתוכנן הוא `EXCHANGE PARTITION` מול טבלה ריקה (`EXCLUDING INDEXES WITHOUT VALIDATION`), ואז `DROP PARTITION`, ובסוף `DROP TABLESPACE ... INCLUDING CONTENTS`. הידע על המסלול מגיע מפוסט מ-2010 על גרסה 11.2 ומהערת Oracle Support שלא ניתן היה לקרוא במלואה, ולכן **הוא חייב להיבדק על הגרסה שלך ב-POC**.

## LOB: האם נדרש טיפול שונה? כן

| נושא | מה קורה | מה הפתרון עושה |
|---|---|---|
| **MOVE לא מזיז LOB** | בלי סעיף LOB מפורש, ה-LOB נשאר ב-tablespace הישן ושובר את ההפרדה | התוכנית מוסיפה `LOB (c) STORE AS (TABLESPACE x)` לכל עמודה |
| **ניקוי ביעד** | ייתכן שאי אפשר לנקות טבלת LOB כשה-tablespace לא מקוון | ברירת המחדל `LOB_HIST_SKIP=N`: היסטוריית LOB **משוחזרת**, ואז נמחקת ביעד. עולה באחסון זמני, אבל בטוח. אחרי POC חיובי אפשר לעבור ל-`Y` |
| **LOB index** | זז יחד עם ה-LOB ואין להזיז אותו בנפרד | ממופה לגודל ולסיווג בלבד |
| **LOB במיקום אחר מהטבלה** | שכיח, ושובר את R3 | כלל L02 מאתר, והתוכנית מיישרת. גם אם רק ה-LOB צריך לזוז, הפעולה כותבת מחדש גם את סגמנט הטבלה |
| **BasicFile** | איטי ולרוב סדרתי | כלל L03 מתריע מעל `BASICFILE_WARN_GB`. מומלץ לתזמן בנפרד |
| **SecureFile** | דורש ASSM, ו-CHUNK תלוי בגודל הבלוק | בדיקות P11, P25. tablespaces חדשים הם ASSM ובאותו גודל בלוק |
| **דחיסה, dedup, הצפנה** | נשמרים ב-MOVE, ודורשים רישוי או wallet ביעד | כלל L04 מדווח |
| **XMLType, אובייקטים, עמודה מוסתרת** | אי אפשר לנסח סעיף LOB פשוט | כלל L06, והצעד מסומן `MANUAL` |

## ארכיטקטורה

```
שער 0  POC על מסד בדיקה           poc/poc_offline_cleanup.sql
   |
שלב 1  מיפוי ללא התקנה             sql/00_adhoc_mapping_readonly.sql
   |
שלב 2  התקנת PCOPY, מיפוי ובדיקות  PCOPY_MAP -> PCOPY_CHECK
   |     סקירת החלטות ודריסה ידנית
   |
שלב 3  תוכנית ובדיקות מקדימות      PCOPY_PLAN -> PCOPY_PRECHECK
   |     סקירת כל פקודות ה-DDL
   |
שלב 4  הזזה ו-rebuild ביצור        PCOPY_EXEC  <-- כאן היצור משתנה
   |     rebuild_unusable, run_post
   |
שלב 5  גיבוי חדש ומיפוי סופי       assert_ready חייב לעבור
   |
שלב 6  שחזור חלקי ביעד             rman/generate_restore_script.sql
   |
שלב 7  ניקוי ביעד                  PCOPY_TARGET (ברירת מחדל: dry run)
   |
שלב 8  nid, מיסוך, סטטיסטיקות      rman/target_runbook.sql
```

## מודל ההחלטה

מיקום נתון היסטורי ב-tablespace משוחזר **אינו הפרה**. זה רק בזבוז מקום זמני, כי ה-partition נמחק ביעד. הפרה קיימת רק כשמשהו שנדרש ביעד יושב ב-tablespace שמדלגים עליו. לכן אפשר להזיז רק את מה שמשתלם, וזה קריטי ב-80TB.

| סיווג tablespace | החלטה | פעולה |
|---|---|---|
| `PURE_HIST`, היסטוריה רגילה | `SKIP` | אין |
| `PURE_HIST`, היסטוריה שדורשת ניקוי מקוון (LOB ועוד) | `RESTORE_DROP` | משוחזר, מרוקן ונמחק ביעד |
| `PURE_KEEP`, `EMPTY`, `SYSTEM` | `RESTORE` | אין |
| `MIXED`, היסטוריה מתחת ל-`MIN_SAVING_GB` | `RESTORE` | `LEAVE` |
| `MIXED`, הנתונים החדשים קטנים או שווים להיסטוריה | `SKIP` | `MOVE_KEEP_OUT` |
| `MIXED`, הנתונים החדשים גדולים מההיסטוריה, או שיש אובייקטים שלא ניתן להזיז | `RESTORE` | `MOVE_HIST_OUT` |

- כל החלטה ניתנת לדריסה עם `pcopy_map.set_ts_decision`, והדריסה נרשמת בלוג.
- היסטוריה שזזה עוברת קודם ל-tablespaces היסטוריים קיימים שיש בהם מקום (כולל read only, שנפתחים ונסגרים), אחרת ל-`HIST_<YYYY>` חדש. `PREFER_EXISTING_HIST_TS=N` מכריח יצירת tablespaces חדשים, וחוסך גיבוי מחדש של tablespaces ישנים.
- עם הזמן partitions חדשים הופכים להיסטוריים, ועדיין נשארים ב-tablespace משוחזר. זה בזבוז מקום בלבד, ולא שובר את ההפרדה.
- טבלה שכל ה-partitions שלה היסטוריים שומרת את החדש ביותר, כי Oracle אוסר למחוק את האחרון (ORA-14083).

## תהליכי הזזה ו-rebuild

| מצב | פקודה | אינדקסים |
|---|---|---|
| **COLD** (היסטוריה) | `MOVE PARTITION ... LOB ... [UPDATE GLOBAL INDEXES] PARALLEL n` | האינדקס המקומי של אותו partition הופך ל-UNUSABLE, ואחר כך `REBUILD PARTITION ... TABLESPACE x` |
| **HOT** (נתונים חדשים) | `MOVE PARTITION ... LOB ... UPDATE INDEXES PARALLEL n ONLINE` | כל האינדקסים נשארים תקינים, ו-`REBUILD ... ONLINE` רק כדי להעביר אינדקס מקומי ליעד |
| טבלה ללא partitions | `MOVE ONLINE TABLESPACE ... UPDATE INDEXES` | `REBUILD ... ONLINE` בשלב 50 |
| composite | `MOVE SUBPARTITION`, ו-`REBUILD SUBPARTITION` | כנ"ל, ברמת subpartition |

טיפולים נוספים:

- כל Rebuild תלוי בהצלחת ה-MOVE שלו, אחרת הוא מסומן `SKIPPED`.
- `pcopy_exec.rebuild_unusable` מטפל רק במה שהתהליך גרם, על בסיס baseline שנלקח לפני השינוי. אינדקס שהיה UNUSABLE קודם לא ייגע בו.
- `PARALLEL` נשמר על האובייקט אחרי rebuild, לכן שלב 70 מחזיר את ה-degree המקורי.
- שלב 60 מעדכן default attributes של טבלה, אינדקס, LOB ו-interval, אחרת partitions עתידיים ייווצרו ב-tablespace שמדלגים עליו.

## בדיקות לפני הזזה ביצור

`pcopy_precheck.run_pre`. תוצאת FAIL או בדיקה ישנה מ-`PRECHECK_MAX_AGE_HOURS` חוסמות את ההרצה.

| קוד | נושא | קוד | נושא |
|---|---|---|---|
| P01, P02 | גרסה ו-Enterprise Edition | P13, P22 | נעילות ועסקאות ארוכות |
| P03 | ARCHIVELOG ו-FORCE LOGGING | P14 | האם ההיסטוריה באמת לא פעילה |
| P04, P05 | גיבוי אחרון, וגיבוי שרץ עכשיו | P15 | baseline של אינדקסים ואובייקטים |
| P06, P07 | FRA מול נפח ה-redo הצפוי | P16, P17 | Temp ו-parallel_max_servers |
| P08, P23 | Data Guard ו-standby_file_management | P18 | jobs שרצים |
| P09, P24 | מקום ב-tablespaces וב-disk groups | P19 | Block Change Tracking |
| P10 | OMF ל-tablespaces חדשים | P20 | כתיבה ל-alert log בפועל |
| P11, P25 | LOB מול ASSM וגודל בלוק | P21 | restore point מובטח |
| P12, P26 | הפרות קריטיות וצעדים ידניים | | |

**במהלך הריצה**, לפני כל צעד נבדקים: `STOP_FLAG`, חלון עבודה, אחוז FRA, יעדי ארכיב ו-lag של Data Guard. אפשר לעצור מכל session:

```sql
UPDATE pcopy_config SET param_value = 'Y' WHERE param_name = 'STOP_FLAG'; COMMIT;
```

## לוגים ו-alert log

| טבלה | תוכן |
|---|---|
| `PCOPY_RUN` | כל ריצה: cutoff, SCN, סטטוס |
| `PCOPY_LOG` | כל פעולה, עם ה-SQL, קוד ORA ו-stack, בטרנזקציה אוטונומית |
| `PCOPY_PLAN_STEP` | כל צעד: סטטוס, ניסיונות, זמן, redo, שגיאה |
| `PCOPY_PRECHECK` | תוצאות בדיקות לפני ואחרי |
| `PCOPY_VIOLATION` | הפרות לפי כלל, חומרה וסוג תיקון |
| `PCOPY_PARTITION_MAP`, `PCOPY_SEGMENT_MAP`, `PCOPY_TS_MAP` | תמונת המיפוי של כל ריצה |
| `PCOPY_BASELINE` | המצב לפני השינוי |

כל שגיאה נכתבת גם ל-alert log דרך `DBMS_SYSTEM.KSDWRT`, בשורה אחת שאפשר לנטר:

```
PCOPY-ERROR run=12 step=3456 module=PCOPY_EXEC action=MOVE_PART obj=APP.T_SALES:P_2021 ORA-01653: ...
```

ב-RAC ההודעה נכתבת ל-alert log של ה-instance שבו רצה ה-session. `DBMS_SYSTEM` אינו מתועד רשמית.

## סדר ביצוע

### שער 0: POC, על מסד בדיקה בלבד

```bash
sqlplus / as sysdba @poc/poc_offline_cleanup.sql <TEST_DB_NAME>
```

| תוצאה | החלטה |
|---|---|
| `S4_LOB`, `S5_LOBB` עוברים את 2c | `LOB_HIST_SKIP=Y`, נחסך אחסון זמני |
| `S4_LOB`, `S5_LOBB` נכשלים | נשארים עם `N`, היסטוריית LOB משוחזרת ואז נמחקת |
| `S2`, `S3` נכשלים ב-2c ועוברים ב-4b | exchange לא מספיק, נדרש מסלול drop indexes, drop partition, create indexes. **מסלול זה עדיין לא ממומש בחבילה** |
| גם 4b נכשל | אין ניקוי במצב לא מקוון, וכל ההיסטוריה עוברת ל-`RESTORE_DROP`. חיסכון האחסון הזמני אובד, ויש לבחון את התכן מחדש |

ה-POC משתמש ב-tablespace במצב `OFFLINE`. **לפני ביצוע ביצור נדרשת גם חזרה מלאה**: שחזור חלקי אמיתי של מסד קטן עם `SKIP FOREVER`, כולל `target_runbook.sql`.

### שלבים 1 עד 8

1. `sql/00_adhoc_mapping_readonly.sql <cutoff>`: תמונת מצב ראשונה, ללא התקנה. כבד על `DBA_SEGMENTS`, להריץ בשעות שקטות.
2. `install/01_user_grants.sql` כ-SYS, ואז `install/install_all.sql` כ-PCOPY.
3. `sql/10_run_production.sql` בלוק אחר בלוק, ו-`sql/11_reports.sql <run_id>` לסקירה.
4. פיילוט על טבלה קטנה, ואז קבוצות עם `p_max_gb`, עם גיבוי ארכיב ביניהן.
5. `rebuild_unusable`, `run_post`, גיבוי חדש, מיפוי סופי ו-`assert_ready`.
6. `rman/generate_restore_script.sql <run> <dest> <until_scn> <channels>`. ה-SCN חייב להיות גבוה מ-`MAP_SCN`.
7. `rman/target_runbook.sql`: שחזור, פתיחה מוגבלת, dry run ואז ניקוי אמיתי.
8. `nid`, מיסוך, סטטיסטיקות והקטנת קבצים.

## סיכונים ונקודות לתשומת לב

| סיכון | התמודדות |
|---|---|
| **נפח redo ו-Data Guard** | כל GB שזז מייצר redo. קבוצות קטנות, ניטור FRA ו-lag, עצירה אוטומטית |
| **נעילות ב-COLD** | P14 מזהה partitions פעילים. אפשר לעבור ל-HOT |
| **ONLINE אסור** | domain index, bitmap join index, טיפוסי אובייקט ו-IOT. נתונים חדשים בטבלאות כאלה מסומנים `MANUAL` |
| **שינוי DDL בין המיפוי לשחזור** | `MAP_SCN`, ו-`check_target` עוצר אם חסר ביעד אובייקט נדרש |
| **גיבוי ישן של RO** | tablespace שנפתח ושונה דורש גיבוי חדש. בדיקה A05 מפרטת אילו |
| **אינדקסים גלובליים** | משוחזרים בגודל מלא ודורשים rebuild ביעד. V06 מציג את העלות |
| **FK לטבלה שאיבדה partitions** | שורות בן יתומות. ה-FK חוזר כ-`ENABLE NOVALIDATE` |
| **הרצה בטעות ביצור** | `PCOPY_TARGET` בודק `DB_UNIQUE_NAME` ו-`RESETLOGS`. הרשאות הניקוי ניתנות רק ביעד |
| **HCC** | בלוקי HCC ניתנים לקריאה רק על אחסון תומך (V15) |
| **חיבור ליצור מהעותק** | שחזור בלי ה-catalog של היצור, `job_queue_processes=0`, סקירת DB links ו-jobs |
| **נתונים רגישים** | מיסוך לפני פתיחה למשתמשים נדרש ואינו חלק מהכלי |
| **הרשאות PCOPY** | רחבות (`ALTER ANY TABLE` ועוד). לנעול את החשבון מחוץ לחלון העבודה ולבטל בסיום |

### לא ממומש

- מסלול הניקוי החלופי drop indexes, drop partition, create indexes (הפעלתו תלויה בתוצאת ה-POC).
- תיקון אוטומטי של IOT, טבלאות מקוננות, XMLType, subpartition template ו-LONG. אלה מדווחים ומסומנים ידני.
- זיהוי היסטוריה לפי רמת subpartition (למשל LIST-RANGE), מפתחות מרובי עמודות ו-LIST על תאריך. טבלאות כאלה מובאות במלואן, ו-V10 מדווח עליהן.
- מיסוך נתונים.

## מבנה התיקייה

```
install/   01_user_grants  02_tables  03_pkg_util  04_pkg_map  05_pkg_check
           06_pkg_plan  07_pkg_precheck  08_pkg_exec  09_pkg_target  install_all
sql/       00_adhoc_mapping_readonly  10_run_production  11_reports
poc/       poc_offline_cleanup
rman/      generate_restore_script  target_grants  target_runbook
```

## מקורות

- [Oracle: RMAN-05548](https://docs.oracle.com/en/error-help/db/rman-05548)
- [Oracle 19c VLDB: Maintenance Operations Supported on Partitions](https://docs.oracle.com/en/database/oracle/oracle-database/19/vldbg/maintenance-partition-can-be-performed.html)
- [Oracle 19c SQL Reference: ALTER TABLE](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/ALTER-TABLE.html)
- [Oracle Support 267125.1: How To Drop An Offlined Tablespace When Partitions Reside In It](https://support.oracle.com/knowledge/Oracle%20Database%20Products/267125_1.html) (נקרא רק תקציר מתוך תוצאות חיפוש)
- [Randolf Geist: Cleanup of partitioned objects residing in offlined tablespaces](https://oracle-randolf.blogspot.com/2010/) (2010, גרסה 11.2)
- [dbakevin: duplicate database from tape without target DB](https://dbakevin.blogspot.com/2012/07/rman-senior-duplicate-database-from.html) (2012, גרסה 11.2)
- [Pythian: RMAN Skip Tablespace Issue](https://www.pythian.com/blog/rman-skip-tablespace-issue/)
