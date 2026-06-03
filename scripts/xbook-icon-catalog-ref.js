  const XBOOK_SERVICE_ICON_ACCENT = "#64748b";

  const XBOOK_SERVICE_ICON_CATEGORIES = [
    {
      id: "hair",
      label: "Hair",
      catIcon: "cat_hair",
      icons: [
        { key: "haircut", label: "Haircut" },
        { key: "hair_coloring", label: "Hair Coloring" },
        { key: "haircut_beard_trim", label: "Haircut & Beard Trim" }
      ]
    },
    {
      id: "beauty",
      label: "Beauty",
      catIcon: "cat_beauty",
      icons: [
        { key: "nails", label: "Nails" },
        { key: "facial", label: "Facial" },
        { key: "pedicure", label: "Pedicure" },
        { key: "makeup", label: "Makeup" }
      ]
    },
    {
      id: "relax",
      label: "Relax",
      catIcon: "cat_relax",
      icons: [
        { key: "massage", label: "Massage" },
        { key: "anti_cellulite_massage", label: "Anti-Cellulite Massage" },
        { key: "spa_swimming", label: "Spa & Swimming" }
      ]
    },
    {
      id: "dental",
      label: "Dental",
      catIcon: "cat_dental",
      icons: [
        { key: "teeth", label: "Teeth" },
        { key: "teeth_polishing", label: "Teeth Polishing" },
        { key: "dental_prosthesis", label: "Dental Prosthesis" }
      ]
    },
    {
      id: "body",
      label: "Body",
      catIcon: "cat_body",
      icons: [
        { key: "training", label: "Training" },
        { key: "yoga", label: "Yoga" },
        { key: "chiropractic", label: "Chiropractic" }
      ]
    }
  ];

  const SERVICE_ICON_PATHS = {
    cat_hair:
      "<circle cx='6' cy='6' r='2.75'/><circle cx='6' cy='18' r='2.75'/><path d='M8.5 8.5 12 12m0 0 3.5 3.5M12 12l3.5-3.5M12 12l-3.5 3.5'/>",
    cat_beauty:
      "<path d='M9 5.5h6v12H9z'/><path d='M10.5 5.5V4h3v1.5'/><path d='M15 10.5 17 9 15 7.5z'/>",
    cat_relax:
      "<circle cx='12' cy='7' r='2'/><path d='M8.5 18c1.2-2 2.6-3 3.5-3s2.3 1 3.5 3'/><path d='M9.5 12.5h5'/><path d='M10.5 9.5 12 12l1.5-2.5'/>",
    cat_dental:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/>",
    cat_body:
      "<circle cx='12' cy='5.5' r='2'/><path d='M8.5 19.5c1.6-2.5 6.9-2.5 7 0'/><path d='M9.5 11.5h5'/>",
    haircut:
      "<circle cx='6' cy='6' r='2.75'/><circle cx='6' cy='18' r='2.75'/><path d='M8.5 8.5 12 12m0 0 3.5 3.5M12 12l3.5-3.5M12 12l-3.5 3.5'/>",
    hair_coloring:
      "<path d='M9 15h6v2.5H9z'/><path d='M12 15V8.5'/><path d='M10.5 8.5 12 6l1.5 2.5'/>",
    haircut_beard_trim:
      "<circle cx='12' cy='8.5' r='3.25'/><path d='M8.5 15c.9 1.6 2.1 2.5 3.5 2.5s2.6-.9 3.5-2.5'/><path d='M9.5 15c0 1.1.9 1.9 2.5 2.1s2.4-.8 2.5-2.1'/>",
    nails:
      "<path d='M10.5 7h3v7.5a1.4 1.4 0 0 1-3 0V7z'/><path d='M16.2 9.2l.7 1.1-.7 1.1'/><path d='M16.5 8.8v2.8'/>",
    facial:
      "<circle cx='12' cy='11' r='3.5'/><path d='M8 8.5h8'/><path d='M15.8 13.8 17.5 16l-2.2 1.2-1-2.4z'/>",
    pedicure:
      "<path d='M7.5 16.2c1.7-.7 3.1-1.1 4.5-1.1s2.8.4 4.5 1.1'/><path d='M9.2 12h5.6'/><path d='M16 10.2l.55.9-.55.9'/><path d='M15.7 9.8v2'/>",
    makeup:
      "<path d='M6.5 19.5 8.5 8l1.8 6.2 1.7-6.2 1.8 6.2 2-11.5'/>",
    massage:
      "<path d='M5.5 14.5h13'/><path d='M8.2 14.5v-2.2c0-1.4 1-2.3 2.4-2.3h3.2c1.3 0 2.2.9 2.2 2.3v2.2'/><path d='M10.2 12h3.6'/>",
    anti_cellulite_massage:
      "<path d='M10.2 6.5v11M13.8 6.5v11'/><path d='M9.2 10.2h1.4M13.4 10.2h1.4M9.2 13.8h1.4M13.4 13.8h1.4'/><path d='M11.2 9.2 9.8 11.2l1.4 2M12.8 9.2l1.4 2-1.4 2'/>",
    spa_swimming:
      "<path d='M6.5 16.8h11v2.7H6.5z'/><path d='M9.5 13.2v3.6M14.5 13.2v3.6'/><path d='M8.5 9.2h7'/><path d='M10 7h4v2.2h-4z'/>",
    teeth:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/>",
    teeth_polishing:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><path d='M16.8 5.8l.7 1-.7 1'/><path d='M7.2 5.8l-.7 1 .7 1'/><path d='M12 3.8v1.2'/>",
    dental_prosthesis:
      "<path d='M7.2 11.8c1-1.8 2.8-2.8 4.8-2.8s3.8 1 4.8 2.8'/><path d='M7.2 14.8c1 1.8 2.8 2.8 4.8 2.8s3.8-1 4.8-2.8'/>",
    training:
      "<path d='M4.5 10.5h5.5v8.5H4.5zM14 9h5.5v10H14z'/><path d='M7 9V7M17 7v2'/>",
    yoga:
      "<circle cx='12' cy='7' r='2'/><path d='M8.5 18.5c1.8-2.8 5.2-2.8 7 0'/><path d='M10 13.5h4'/><path d='M12 10.5v3'/>",
    chiropractic:
      "<path d='M12 5v14'/><path d='M9.5 8.5h5M9.5 12h5M9.5 15.5h5'/>"
  };
