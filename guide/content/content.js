/* GT Termin Business Owner Guide — all content in MK (default), EN and SQ.
   [[Label]] renders as an app-label chip; **text** renders bold. Labels match the current GT Termin app
   (index.html i18n dictionaries). Facts verified against the app source on 2026-11-12. */
window.GTG = window.GTG || {};

(function () {
  /* Real screenshot (per language) or a clearly marked "needed" placeholder. Never a mockup. */
  function real(name, markers) {
    return {
      src: { mk: "assets/img/app/" + name + "-mk.webp", en: "assets/img/app/" + name + "-en.webp", sq: "assets/img/app/" + name + "-sq.webp" },
      size: [786, 1704],
      markers: markers || []
    };
  }
  /* Real screenshot captured only in Macedonian so far (iPhone, Liquid Glass Light, 920×2000).
     EN/SQ fall back to it and show a small "shown in Macedonian" caption. Personal data is blurred. */
  function realMk(name, markers) {
    return {
      src: { mk: "assets/img/app/" + name + "-mk.webp" },
      size: [920, 2000],
      markers: markers || []
    };
  }
  function needed(mk, en, sq) {
    return { needed: { mk: mk, en: en, sq: sq } };
  }

  window.GTG.steps = [
    /* ---------------- Step 1 ---------------- */
    {
      id: "setup",
      short: { mk: "Бизнис", en: "Business", sq: "Biznesi" },
      icon: "store",
      minutes: 5,
      title: { mk: "Поставете го бизнисот", en: "Set up your business", sq: "Konfiguroni biznesin" },
      lead: {
        mk: "Од преземање до подготвен профил за неколку минути.",
        en: "From download to a ready business profile in a few minutes.",
        sq: "Nga shkarkimi te një profil biznesi gati, për pak minuta."
      },
      cards: [
        {
          title: { mk: "Креирајте бизнис-сметка", en: "Create a business account", sq: "Krijoni llogari biznesi" },
          text: {
            mk: "Преземете GT Termin од App Store или Google Play. На почетниот екран допрете [[Креирај бизнис сметка]]. Копчето [[Креирај клиентска сметка]] е за вашите клиенти.",
            en: "Download GT Termin from the App Store or Google Play. On the welcome screen, tap [[Create Business Account]]. The [[Create Customer Account]] button is for your customers.",
            sq: "Shkarkoni GT Termin nga App Store ose Google Play. Në ekranin e mirëseardhjes prekni [[Krijo llogari biznesi]]. Butoni [[Krijo llogari klienti]] është për klientët tuaj."
          },
          shot: real("welcome", [[52, 765, 734, 870]])
        },
        {
          title: { mk: "Е-пошта и лозинка", en: "E-mail and password", sq: "Email-i dhe fjalëkalimi" },
          text: {
            mk: "Внесете е-пошта и лозинка (најмалку 6 знаци) и допрете [[Креирај бизнис сметка]]. Потоа отворете ја пораката што ја добивте и потврдете ја е-поштата пред да се најавите.",
            en: "Enter your e-mail and a password (at least 6 characters) and tap [[Create Business Account]]. Then open the message you receive and confirm your e-mail before signing in.",
            sq: "Shkruani email-in dhe një fjalëkalim (të paktën 6 karaktere) dhe prekni [[Krijo llogari biznesi]]. Pastaj hapni mesazhin që merrni dhe konfirmoni email-in para se të hyni."
          },
          shot: real("signup")
        },
        {
          title: { mk: "Поставување во 6 кратки чекори", en: "Setup in 6 short steps", sq: "Konfigurimi në 6 hapa të shkurtër" },
          text: {
            mk: "По првата најава GT Termin ве води низ [[Бизнис]], [[Услуги]], [[Часови]], [[Тим]], [[Правила]] и [[Преглед]]. Задолжителни се името, типот и телефонот. Изберете и [[Вашиот бизнис код]] — со него клиентите ве наоѓаат. Лого додавате во [[Дополнителни информации]] → [[Прикачи лого]]. На крајот допрете [[Зачувај и активирај GT Termin]].",
            en: "After your first sign-in, GT Termin walks you through [[Business]], [[Services]], [[Hours]], [[Team]], [[Rules]] and [[Review]]. Name, type and phone are required. Also choose [[Your business code]] — customers use it to find you. Add a logo in [[Optional details]] → [[Upload logo]]. Finish with [[Save & Launch GT Termin]].",
            sq: "Pas hyrjes së parë, GT Termin ju udhëheq nëpër [[Biznesi]], [[Shërbimet]], [[Orari]], [[Ekipi]], [[Rregullat]] dhe [[Rishikimi]]. Emri, lloji dhe telefoni janë të detyrueshëm. Zgjidhni edhe [[Kodi juaj i biznesit]] — klientët ju gjejnë me të. Logon e shtoni te [[Detaje opsionale]] → [[Ngarko logon]]. Në fund prekni [[Ruaj dhe hap GT Termin]]."
          },
          shot: realMk("wizard-business")
        },
        {
          title: { mk: "Профил што го гледаат клиентите", en: "The profile customers see", sq: "Profili që shohin klientët" },
          text: {
            mk: "Во [[Подесувања]] → [[Бизнис идентитет]] додајте насловна слика, галерија и [[Контакт и локација]]. Повеќето промени важат откако ќе допрете [[Зачувај промени]]. Со [[Види како клиент]] проверете како изгледа.",
            en: "In [[Settings]] → [[Business identity]], add a cover image, gallery and [[Contact & location]]. Most changes apply after you tap [[Save Changes]]. Use [[Preview as Customer]] to check how it looks.",
            sq: "Te [[Cilësimet]] → [[Identiteti i biznesit]] shtoni imazh kopertine, galeri dhe [[Kontakti dhe vendndodhja]]. Shumica e ndryshimeve vlejnë pasi të prekni [[Ruaj ndryshimet]]. Me [[Shiko si klient]] kontrolloni si duket."
          },
          tip: {
            mk: "Нешто да смените подоцна? [[Подесувања]] → [[Брзо уредување на бизнисот]] го отвора истото поставување.",
            en: "Need to change something later? [[Settings]] → [[Quick business setup]] reopens the same setup.",
            sq: "Doni të ndryshoni diçka më vonë? [[Cilësimet]] → [[Konfigurim i shpejtë i biznesit]] e hap të njëjtin konfigurim."
          }
        }
      ]
    },

    /* ---------------- Step 2 ---------------- */
    {
      id: "services",
      short: { mk: "Услуги", en: "Services", sq: "Shërbimet" },
      icon: "scissors",
      minutes: 3,
      title: { mk: "Додајте ги услугите", en: "Add your services", sq: "Shtoni shërbimet" },
      lead: {
        mk: "Што нудите, колку трае и колку чини.",
        en: "What you offer, how long it takes and what it costs.",
        sq: "Çfarë ofroni, sa zgjat dhe sa kushton."
      },
      cards: [
        {
          title: { mk: "Нова услуга", en: "A new service", sq: "Shërbim i ri" },
          text: {
            mk: "Услугите ги додавате во поставувањето (чекор [[Услуги]]) или подоцна во [[Подесувања]] → [[Услуги и тим]] → [[Услуги]] → [[Додај нова услуга]]. Внесете [[Име на услугата]], по желба сликичка ([[Визуел на услугата]]) и изберете [[Времетраење]] — од 15 до 120 мин.",
            en: "Add services in the setup ([[Services]] step) or later in [[Settings]] → [[Services & team]] → [[Services]] → [[Add new service]]. Enter the [[Service name]], optionally an icon ([[Service visual]]) and choose a [[Duration]] — from 15 to 120 min.",
            sq: "Shërbimet i shtoni gjatë konfigurimit (hapi [[Shërbimet]]) ose më vonë te [[Cilësimet]] → [[Shërbimet dhe ekipi]] → [[Shërbimet]] → [[Shto shërbim të ri]]. Shkruani [[Emri i shërbimit]], sipas dëshirës një ikonë ([[Pamja e shërbimit]]) dhe zgjidhni [[Kohëzgjatja]] — nga 15 deri në 120 min."
          },
          shot: realMk("service-add")
        },
        {
          title: { mk: "Свое времетраење и цена", en: "Custom duration and price", sq: "Kohëzgjatje e personalizuar dhe çmimi" },
          text: {
            mk: "Ако ниедно понудено време не одговара, внесете свое во [[Прилагодено времетраење (минути)]] — на пример 20, 40 или 75. [[Цена (изборно)]] оставете ја празна за бесплатна услуга. Допрете [[Зачувај услуга]].",
            en: "If none of the offered durations fits, enter your own in [[Custom duration (minutes)]] — for example 20, 40 or 75. Leave [[Price (optional)]] empty for a free service. Tap [[Save service]].",
            sq: "Nëse asnjë kohëzgjatje e ofruar nuk përshtatet, shkruani tuajën te [[Kohëzgjatje e personalizuar (minuta)]] — për shembull 20, 40 ose 75. [[Çmimi (opsionale)]] lëreni bosh për shërbim falas. Prekni [[Ruaj shërbimin]]."
          },
          example: {
            mk: [["Услуга", "Машко шишање"], ["Времетраење", "30 мин"], ["Цена", "400 MKD"]],
            en: [["Service", "Men's haircut"], ["Duration", "30 min"], ["Price", "400 MKD"]],
            sq: [["Shërbimi", "Qethje për meshkuj"], ["Kohëzgjatja", "30 min"], ["Çmimi", "400 MKD"]]
          },
          shot: realMk("service-price", [[75, 972, 448, 1090]])
        },
        {
          title: { mk: "Уредување и цени", en: "Editing and prices", sq: "Ndryshimi dhe çmimet" },
          text: {
            mk: "Во листата на услуги користете [[Уреди]] или [[Избриши]]. Дали клиентите ги гледаат цените одлучувате со [[Прикажи цени на услугите]] — по промената допрете [[Зачувај промени]].",
            en: "In the services list, use [[Edit]] or [[Delete]]. Whether customers see prices is controlled by [[Show service prices]] — after changing it, tap [[Save Changes]].",
            sq: "Në listën e shërbimeve përdorni [[Ndrysho]] ose [[Fshi]]. Nëse klientët i shohin çmimet e vendosni me [[Shfaq çmimet e shërbimeve]] — pas ndryshimit prekni [[Ruaj ndryshimet]]."
          },
          shot: needed(
            "Листа на услуги со „Прикажи цени на услугите“",
            "Services list with “Show service prices”",
            "Lista e shërbimeve me “Shfaq çmimet e shërbimeve”"
          )
        }
      ],
      note: {
        mk: "Услугите не се врзуваат за одреден член на тимот. Членот се избира кога се закажува терминот, или [[Сите вработени]].",
        en: "Services aren't tied to a specific team member. The team member is chosen when the appointment is booked, or [[All staff]].",
        sq: "Shërbimet nuk lidhen me një anëtar të caktuar të ekipit. Anëtari zgjidhet kur rezervohet termini, ose [[Gjithë stafi]]."
      }
    },

    /* ---------------- Step 3 ---------------- */
    {
      id: "hours",
      short: { mk: "Часови и тим", en: "Hours & team", sq: "Orari & ekipi" },
      icon: "clock",
      minutes: 4,
      title: { mk: "Работно време и тим", en: "Working hours and team", sq: "Orari dhe ekipi" },
      lead: {
        mk: "Кога сте отворени и кој работи.",
        en: "When you're open and who works.",
        sq: "Kur jeni hapur dhe kush punon."
      },
      cards: [
        {
          title: { mk: "Работни денови и часови", en: "Working days and hours", sq: "Ditët dhe orët e punës" },
          text: {
            mk: "Во поставувањето (чекор [[Часови]]) или во [[Подесувања]] → [[Работно време и достапност]] → [[Работно време]] означете ги деновите кога работите и поставете [[Отвора]] и [[Затвора]]. Истото време важи за сите избрани денови.",
            en: "In the setup ([[Hours]] step) or in [[Settings]] → [[Working hours & availability]] → [[Working Hours]], tick the days you work and set [[Opens]] and [[Closes]]. The same hours apply to all selected days.",
            sq: "Gjatë konfigurimit (hapi [[Orari]]) ose te [[Cilësimet]] → [[Orari i punës dhe disponueshmëria]] → [[Orari i punës]] shënoni ditët kur punoni dhe vendosni [[Hapet]] dhe [[Mbyllet]]. E njëjta orë vlen për të gjitha ditët e zgjedhura."
          },
          shot: realMk("hours-days")
        },
        {
          title: { mk: "Различно време по ден", en: "Different hours on some days", sq: "Orar i ndryshëm në disa ditë" },
          text: {
            mk: "Ако некој ден работите поинаку (на пример сабота), отворете [[Различно работно време или пауза]], во [[Различно работно време по ден]] штиклирајте го денот и внесете посебно време.",
            en: "If you work different hours on some day (Saturday, for example), open [[Different hours or break]], tick that day under [[Different hours by weekday]] and enter its own hours.",
            sq: "Nëse një ditë punoni ndryshe (p.sh. të shtunën), hapni [[Orar i ndryshëm ose pushim]], te [[Orar i ndryshëm sipas ditës]] shënoni ditën dhe vendosni orarin e saj."
          },
          shot: realMk("hours-different")
        },
        {
          title: { mk: "Пауза и правила за закажување", en: "Break and booking rules", sq: "Pushimi dhe rregullat e rezervimit" },
          text: {
            mk: "По желба поставете пауза со [[Паузата започнува]] и [[Паузата завршува]]. Под неа изберете **колку однапред** клиентите можат да закажат и **колку најдоцна пред терминот**. Подоцна ги менувате во [[Подесувања]] → [[Клиенти и резервации]] → [[Правила за резервации]].",
            en: "Optionally set a break with [[Break starts]] and [[Break ends]]. Below it, choose **how far in advance** customers can book and **how soon before an appointment** they still can. Change these later in [[Settings]] → [[Clients & bookings]] → [[Booking Rules]].",
            sq: "Sipas dëshirës vendosni pushim me [[Pauza fillon]] dhe [[Pauza mbaron]]. Poshtë zgjidhni **sa herët** mund të rezervojnë klientët dhe **sa afër terminit** mund të rezervojnë ende. Më vonë i ndryshoni te [[Cilësimet]] → [[Klientët dhe rezervimet]] → [[Rregullat e rezervimeve]]."
          },
          example: {
            mk: [["Пауза", "12:00–12:30"], ["Однапред", "6 месеци"], ["Најдоцна", "1 час пред терминот"]],
            en: [["Break", "12:00–12:30"], ["In advance", "6 months"], ["At the latest", "1 hour before"]],
            sq: [["Pushimi", "12:00–12:30"], ["Paraprakisht", "6 muaj"], ["Më së voni", "1 orë përpara"]]
          },
          shot: realMk("hours-break-rules")
        },
        {
          title: { mk: "Неработни денови и празници", en: "Days off and holidays", sq: "Ditë pushimi dhe festa" },
          text: {
            mk: "Во [[Неработни денови]] допрете [[Изберете неработни денови рачно]]: изберете денови или опсег, по желба причина, и потврдете. Со [[Блокирај ги државните празници]] клиентите не закажуваат на празник.",
            en: "In [[Non-working Days]], tap [[Choose closed days manually]]: pick days or a range, add a reason if you like, and confirm. With [[Block public holidays]], customers can't book on public holidays.",
            sq: "Te [[Ditët jo pune]] prekni [[Zgjidhni ditët e mbyllura manualisht]]: zgjidhni ditë ose një interval, sipas dëshirës një arsye, dhe konfirmoni. Me [[Blloko festat zyrtare]] klientët nuk rezervojnë në festa."
          }
        },
        {
          title: { mk: "Вашиот тим", en: "Your team", sq: "Ekipi juaj" },
          text: {
            mk: "Во поставувањето (чекор [[Тим]]) допрете [[Додај член на тимот]]: име, улога и по желба фотографија. Кај секој член имате [[Уреди]] и [[Отстрани]]. Подоцна, во [[Подесувања]] → [[Услуги и тим]] → [[Тим]], кај членот има и [[Отсуство]] (одмор, боледување) и [[Деактивирај]].",
            en: "In the setup ([[Team]] step), tap [[Add team member]]: name, role and optionally a photo. Each member has [[Edit]] and [[Remove]]. Later, in [[Settings]] → [[Services & team]] → [[Team]], a member also has [[Time off]] (vacation, sick leave) and [[Deactivate]].",
            sq: "Gjatë konfigurimit (hapi [[Ekipi]]) prekni [[Shto anëtar ekipi]]: emri, roli dhe sipas dëshirës foto. Te çdo anëtar keni [[Ndrysho]] dhe [[Hiq]]. Më vonë, te [[Cilësimet]] → [[Shërbimet dhe ekipi]] → [[Ekipi]], anëtari ka edhe [[Leje]] (pushim, sëmundje) dhe [[Çaktivizo]]."
          },
          shot: realMk("team-wizard", [[37, 1313, 883, 1432]])
        }
      ],
      note: {
        mk: "Работите без вработени? Не мора да додавате тим — тогаш вие сте давателот на услугите.",
        en: "Working without staff? You don't need to add a team — you are the service provider.",
        sq: "Punoni pa staf? Nuk keni nevojë të shtoni ekip — ofruesi i shërbimeve jeni ju."
      }
    },

    /* ---------------- Step 4 ---------------- */
    {
      id: "invite",
      short: { mk: "Покана", en: "Invite", sq: "Ftesa" },
      icon: "share",
      minutes: 2,
      title: { mk: "Поканете ги клиентите", en: "Invite your customers", sq: "Ftoni klientët" },
      lead: {
        mk: "Клиентите се приклучуваат со линк, QR-код или вашиот код.",
        en: "Customers join with a link, a QR code or your business code.",
        sq: "Klientët bashkohen me lidhje, kod QR ose kodin e biznesit tuaj."
      },
      cards: [
        {
          title: { mk: "Испратете покана", en: "Send an invitation", sq: "Dërgoni ftesë" },
          text: {
            mk: "На [[Почетна]] допрете [[Покани клиенти]] и изберете [[Сподели покана]], [[Копирај линк]] или [[Прикажи QR-код]]. QR-кодот може да го покажете во салонот.",
            en: "On [[Home]], tap [[Invite Customers]] and choose [[Share Invite]], [[Copy Link]] or [[Show QR Code]]. You can display the QR code in your salon.",
            sq: "Te [[Ballina]] prekni [[Fto klientë]] dhe zgjidhni [[Ndaj ftesën]], [[Kopjo lidhjen]] ose [[Shfaq kodin QR]]. Kodin QR mund ta shfaqni në sallon."
          },
          shot: realMk("invite", [[48, 1445, 872, 1855]])
        },
        {
          title: { mk: "Вашиот бизнис код", en: "Your business code", sq: "Kodi i biznesit tuaj" },
          text: {
            mk: "Клиентите можат и сами да го внесат вашиот код во GT Termin. Го наоѓате во [[Подесувања]] → [[Бизнис идентитет]] → [[Бизнис профил]] → [[Вашиот бизнис код]].",
            en: "Customers can also type your code in GT Termin. You'll find it in [[Settings]] → [[Business identity]] → [[Business Profile]] → [[Your business code]].",
            sq: "Klientët mund ta shkruajnë edhe vetë kodin tuaj në GT Termin. E gjeni te [[Cilësimet]] → [[Identiteti i biznesit]] → [[Profili i biznesit]] → [[Kodi juaj i biznesit]]."
          }
        },
        {
          title: { mk: "Одобрување нови клиенти (изборно)", en: "Approving new clients (optional)", sq: "Miratimi i klientëve të rinj (opsional)" },
          text: {
            mk: "Во [[Подесувања]] → [[Клиенти и резервации]] → [[Одобрување клиенти]] вклучете го прекинувачот — промената се зачувува веднаш. Тогаш новите клиенти чекаат ваше одобрување пред да закажат. Кога некој чека, на [[Почетна]] се појавува известување; допрете го и кај клиентот изберете [[Одобри]] или [[Одбиј]]. Исклучено (основно): новите клиенти се приклучуваат без одобрување.",
            en: "In [[Settings]] → [[Clients & bookings]] → [[Client Approval]], turn the switch on — it saves right away. New clients then wait for your approval before they can book. When someone is waiting, a notice appears on [[Home]]; tap it and choose [[Approve]] or [[Reject]] on the client. Off (default): new clients join without approval.",
            sq: "Te [[Cilësimet]] → [[Klientët dhe rezervimet]] → [[Miratimi i klientëve]] aktivizoni çelësin — ruhet menjëherë. Atëherë klientët e rinj presin miratimin tuaj para se të rezervojnë. Kur dikush pret, te [[Ballina]] shfaqet njoftim; prekeni dhe te klienti zgjidhni [[Aprovo]] ose [[Refuzo]]. Joaktiv (parazgjedhje): klientët e rinj bashkohen pa miratim."
          },
          shot: realMk("client-approval", [[712, 410, 822, 484]])
        }
      ]
    },

    /* ---------------- Step 5 ---------------- */
    {
      id: "appointments",
      short: { mk: "Термини", en: "Appointments", sq: "Terminet" },
      icon: "calendar",
      minutes: 4,
      title: { mk: "Управувајте со термините", en: "Manage appointments", sq: "Menaxhoni terminet" },
      lead: {
        mk: "Вашиот ден на еден поглед — закажување, промени и откажување.",
        en: "Your day at a glance — booking, changes and cancellations.",
        sq: "Dita juaj me një shikim — rezervime, ndryshime dhe anulime."
      },
      cards: [
        {
          title: { mk: "Почетниот екран", en: "Your home screen", sq: "Ekrani kryesor" },
          text: {
            mk: "[[Почетна]] го покажува следниот термин, денешниот распоред по член на тимот и што бара ваше внимание, на пример клиенти што чекаат одобрување.",
            en: "[[Home]] shows your next appointment, today's schedule per team member and anything that needs your attention, such as clients waiting for approval.",
            sq: "[[Ballina]] tregon terminin e ardhshëm, orarin e sotëm për çdo anëtar të ekipit dhe çfarë kërkon vëmendjen tuaj, p.sh. klientë që presin miratim."
          },
          shot: realMk("home")
        },
        {
          title: { mk: "Закажете термин", en: "Book an appointment", sq: "Rezervoni një termin" },
          text: {
            mk: "Во [[Закажи]] изберете услуга и член на тимот — се прикажуваат само слободните времиња. Допрете [[+]] кај слободно време: [[Додај термин]] се отвора веќе пополнет. Најдете го клиентот со [[Пребарај клиент]] или додајте [[+ Нов клиент]] и зачувајте.",
            en: "In [[Book]], choose a service and team member — only free times are shown. Tap [[+]] next to a free time: [[Add booking]] opens already filled in. Find the client with [[Search customer]] or add [[+ Create new customer]], then save.",
            sq: "Te [[Rezervo]] zgjidhni shërbimin dhe anëtarin e ekipit — shfaqen vetëm oraret e lira. Prekni [[+]] pranë një orari të lirë: [[Shto rezervim]] hapet i plotësuar. Gjeni klientin me [[Kërko klient]] ose shtoni [[+ Klient i ri]] dhe ruani."
          },
          shot: realMk("book", [[786, 844, 857, 915]])
        },
        {
          title: { mk: "Сите резервации", en: "All bookings", sq: "Të gjitha rezervimet" },
          text: {
            mk: "Во [[Резервации]] изберете [[Листа]] или [[Календар]] со [[Ден]], [[Недела]] или [[Месец]]. Во месечниот приказ бројот под датумот е бројот на термини тој ден.",
            en: "In [[Bookings]], choose [[List]] or [[Calendar]] with [[Day]], [[Week]] or [[Month]]. In the month view, the number under a date is how many appointments that day has.",
            sq: "Te [[Rezervimet]] zgjidhni [[Lista]] ose [[Kalendari]] me [[Dita]], [[Java]] ose [[Muaji]]. Në pamjen mujore, numri nën datë është numri i termineve atë ditë."
          }
        },
        {
          title: { mk: "Потврда, промена и откажување", en: "Confirming, changing and cancelling", sq: "Konfirmimi, ndryshimi dhe anulimi" },
          text: {
            mk: "Термините што клиентите ги закажуваат онлајн се автоматски **Потврден**. Допрете термин и изберете [[Уреди термин]] за да ги смените датумот, времето, услугата, членот или статусот, или [[Откажи термин]]. [[Избриши]] го брише терминот трајно, по потврда. Статусот **Во исчекување** се појавува само ако вие го поставите.",
            en: "Appointments customers book online are **Confirmed** automatically. Tap an appointment and choose [[Edit appointment]] to change the date, time, service, team member or status, or [[Cancel appointment]]. [[Delete]] removes it permanently, after you confirm. The **Pending** status only appears if you set it yourself.",
            sq: "Terminet që klientët i rezervojnë online janë automatikisht **I konfirmuar**. Prekni një termin dhe zgjidhni [[Ndrysho terminin]] për të ndryshuar datën, orën, shërbimin, anëtarin ose statusin, ose [[Anulo terminin]]. [[Fshi]] e fshin përgjithmonë, pasi të konfirmoni. Statusi **Në pritje** shfaqet vetëm nëse e vendosni ju."
          },
          shot: realMk("booking-detail", [[85, 1265, 835, 1372], [85, 1392, 452, 1498]])
        }
      ]
    }
  ];

  window.GTG.more = [
    {
      icon: "chart",
      title: { mk: "Аналитика и извештаи", en: "Analytics and reports", sq: "Analitika dhe raportet" },
      text: {
        mk: "Во [[Аналитика]] ги гледате термините, клиентите, услугите и тимот за избран период, и извезувате извештај во PDF или CSV.",
        en: "In [[Analytics]] you see appointments, clients, services and team for a chosen period, and export a report as PDF or CSV.",
        sq: "Te [[Analitika]] shihni terminet, klientët, shërbimet dhe ekipin për një periudhë të zgjedhur, dhe eksportoni raport në PDF ose CSV."
      }
    },
    {
      icon: "bell",
      title: { mk: "Известувања", en: "Notifications", sq: "Njoftimet" },
      text: {
        mk: "Добивате известување за [[Нов термин]] и [[Нов клиент]]. Во [[Подесувања]] → [[Известувања]] можете да испратите порака до сите, VIP или избрани клиенти.",
        en: "You're notified about a [[New appointment]] and a [[New client]]. In [[Settings]] → [[Notifications]] you can send a message to all, VIP or selected clients.",
        sq: "Njoftoheni për [[Termin i ri]] dhe [[Klient i ri]]. Te [[Cilësimet]] → [[Njoftimet]] mund t’u dërgoni mesazh të gjithë klientëve, VIP ose të zgjedhurve."
      }
    },
    {
      icon: "palette",
      title: { mk: "Изглед и јазик", en: "Appearance and language", sq: "Pamja dhe gjuha" },
      text: {
        mk: "Во [[GT Termin и сметка]] изберете тема — [[Liquid Glass]], [[Класичен]] или [[Течен метал]] — и јазик: македонски, англиски или албански.",
        en: "In [[GT Termin & account]], choose a theme — [[Liquid Glass]], [[Classic]] or [[Liquid Metal]] — and a language: Macedonian, English or Albanian.",
        sq: "Te [[GT Termin dhe llogaria]] zgjidhni temën — [[Liquid Glass]], [[Klasik]] ose [[Metal i lëngët]] — dhe gjuhën: maqedonisht, anglisht ose shqip."
      }
    },
    {
      icon: "card",
      title: { mk: "Претплата", en: "Subscription", sq: "Abonimi" },
      text: {
        mk: "Новите бизниси добиваат 14 дена бесплатно. Статусот е во [[GT Termin и сметка]] → [[Претплата]]. Платената претплата засега се активира по договор, без плаќање во апликацијата.",
        en: "New businesses get 14 days free. Your status is in [[GT Termin & account]] → [[Subscription]]. Paid subscriptions are currently activated by arrangement, with no payment in the app.",
        sq: "Bizneset e reja marrin 14 ditë falas. Statusi është te [[GT Termin dhe llogaria]] → [[Abonimi]]. Abonimi me pagesë aktualisht aktivizohet me marrëveshje, pa pagesë në aplikacion."
      }
    },
    {
      icon: "help",
      title: { mk: "Помош и поддршка", en: "Help & Support", sq: "Ndihma dhe mbështetja" },
      text: {
        mk: "Во [[Помош и поддршка]] допрете [[Поддршка преку е-пошта]] или пишете на **gtterminsupport@gtwebstudio.com**.",
        en: "In [[Help & Support]], tap [[Email support]] or write to **gtterminsupport@gtwebstudio.com**.",
        sq: "Te [[Ndihma dhe mbështetja]] prekni [[Mbështetje me email]] ose shkruani te **gtterminsupport@gtwebstudio.com**."
      }
    }
  ];

  window.GTG.faq = [
    {
      q: { mk: "Колку чини GT Termin?", en: "How much does GT Termin cost?", sq: "Sa kushton GT Termin?" },
      a: {
        mk: "Новите бизниси имаат 14 дена бесплатен пробен период. Потоа е потребна претплата; цената и условите ви се соопштуваат пред да се согласите. Плановите се во [[Претплата]].",
        en: "New businesses get a 14-day free trial. After that a subscription is needed; the price and terms are communicated to you before you agree. Plans are shown in [[Subscription]].",
        sq: "Bizneset e reja kanë 14 ditë provë falas. Pastaj nevojitet abonim; çmimi dhe kushtet ju komunikohen para se të pranoni. Planet shfaqen te [[Abonimi]]."
      }
    },
    {
      q: { mk: "Дали клиентите плаќаат за закажување?", en: "Do customers pay to book?", sq: "A paguajnë klientët për të rezervuar?" },
      a: {
        mk: "Не. GT Termin не им наплатува на клиентите. Плаќањето за услугата е меѓу вас и клиентот.",
        en: "No. GT Termin doesn't charge customers. Payment for the service is between you and the customer.",
        sq: "Jo. GT Termin nuk u tarifon klientëve. Pagesa për shërbimin është mes jush dhe klientit."
      }
    },
    {
      q: { mk: "Како клиентите го наоѓаат мојот бизнис?", en: "How do customers find my business?", sq: "Si e gjejnë klientët biznesin tim?" },
      a: {
        mk: "Преку поканата: линк или QR-код од [[Покани клиенти]], или со вашиот бизнис код во апликацијата.",
        en: "Through your invitation: a link or QR code from [[Invite Customers]], or by entering your business code in the app.",
        sq: "Përmes ftesës: lidhje ose kod QR nga [[Fto klientë]], ose duke shkruar kodin e biznesit tuaj në aplikacion."
      }
    },
    {
      q: { mk: "Дали морам да ги потврдувам онлајн резервациите?", en: "Do I have to confirm online bookings?", sq: "A duhet t’i konfirmoj rezervimet online?" },
      a: {
        mk: "Не. Термините што клиентите ги закажуваат се автоматски потврдени. Можете да барате одобрување само за **нови клиенти**, со [[Потребно одобрување]].",
        en: "No. Appointments customers book are confirmed automatically. You can require approval only for **new clients**, with [[Require approval]].",
        sq: "Jo. Terminet që rezervojnë klientët konfirmohen automatikisht. Mund të kërkoni miratim vetëm për **klientë të rinj**, me [[Kërko miratim]]."
      }
    },
    {
      q: { mk: "Работам без вработени — дали ми треба тим?", en: "I work without staff — do I need a team?", sq: "Punoj pa staf — a më duhet ekip?" },
      a: {
        mk: "Не. Ако не додадете членови, вие сте давателот на сите услуги.",
        en: "No. If you add no team members, you are the provider of all services.",
        sq: "Jo. Nëse nuk shtoni anëtarë, ju jeni ofruesi i të gjitha shërbimeve."
      }
    },
    {
      q: { mk: "Како да затворам за одмор?", en: "How do I close for a holiday?", sq: "Si ta mbyll për pushime?" },
      a: {
        mk: "Во [[Неработни денови]] изберете ги деновите или опсегот. Тие денови клиентите не можат да закажат.",
        en: "In [[Non-working Days]], select the days or a range. Customers can't book on those days.",
        sq: "Te [[Ditët jo pune]] zgjidhni ditët ose intervalin. Ato ditë klientët nuk mund të rezervojnë."
      }
    },
    {
      q: { mk: "Член на тимот е на одмор. Што да направам?", en: "A team member is on vacation. What do I do?", sq: "Një anëtar i ekipit është me pushime. Çfarë bëj?" },
      a: {
        mk: "Кај членот допрете [[Отсуство]] и додајте ги датумите. Ако веќе има термини во тие денови, GT Termin ве предупредува.",
        en: "On the team member, tap [[Time off]] and add the dates. If they already have appointments on those days, GT Termin warns you.",
        sq: "Te anëtari prekni [[Leje]] dhe shtoni datat. Nëse ka tashmë termine në ato ditë, GT Termin ju paralajmëron."
      }
    },
    {
      q: { mk: "Можам ли да го избришам профилот?", en: "Can I delete my account?", sq: "A mund ta fshij llogarinë?" },
      a: {
        mk: "Да, во [[GT Termin и сметка]] → [[Избриши профил]]. Претходно ги откажувате или завршувате претстојните термини. Бизнисот и неговите податоци се бришат трајно.",
        en: "Yes, in [[GT Termin & account]] → [[Delete account]]. First cancel or complete upcoming appointments. Your business and its data are deleted permanently.",
        sq: "Po, te [[GT Termin dhe llogaria]] → [[Fshi llogarinë]]. Më parë anuloni ose përfundoni terminet e ardhshme. Biznesi dhe të dhënat e tij fshihen përgjithmonë."
      }
    },
    {
      q: { mk: "Каде да побарам помош?", en: "Where can I get help?", sq: "Ku të kërkoj ndihmë?" },
      a: {
        mk: "Пишете на **gtterminsupport@gtwebstudio.com** или во апликацијата отворете [[Помош и поддршка]].",
        en: "Write to **gtterminsupport@gtwebstudio.com** or open [[Help & Support]] in the app.",
        sq: "Shkruani te **gtterminsupport@gtwebstudio.com** ose hapni [[Ndihma dhe mbështetja]] në aplikacion."
      }
    }
  ];
})();
