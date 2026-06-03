  const XBOOK_ICON_STROKE_WIDTH = "1.75";
  const XBOOK_ICON_VIEW = "0 0 24 24";

  const XBOOK_SERVICE_ICON_CATEGORY_COLORS = {
    hair: "#2563eb",
    beauty: "#db2777",
    relax: "#059669",
    dental: "#0891b2",
    body: "#ea580c"
  };

  const SERVICE_ICON_PATHS = {
    haircut:
      "<circle cx='6' cy='6' r='2.75'/><circle cx='6' cy='18' r='2.75'/><path d='M8.5 8.5 12 12m0 0 3.5 3.5M12 12l3.5-3.5M12 12l-3.5 3.5'/>",
    beard_trim:
      "<rect x='5' y='4' width='6' height='14' rx='2'/><path d='M11 8h5l2 3v5h-7V8z'/><path d='M14 6v2'/>",
    haircut_beard:
      "<circle cx='5.5' cy='7' r='2'/><path d='M8 9.5h2.5'/><path d='M13 14c-1.5 0-3-1-4-2.5'/><path d='M17 7.5v9'/><path d='M15.5 6h3'/>",
    beard_shave:
      "<path d='M5 6c2-1 4-1 6 0s4 1 6 0'/><path d='M6 10v8'/><path d='M4 5l14 14'/><path d='M15 4l3 3-3 3'/>",
    hair_coloring:
      "<path d='M12 3c-4.5 0-7 2.5-7 6.5 0 2 1 3 2.5 3 3.5 0 1.5-1 3-3 3-3.5 0-4-2.5-7-6.5S7.5 3 12 3z'/><circle cx='8' cy='10' r='1' fill='currentColor'/>",
    highlights:
      "<path d='M7 5 9 11M17 5 15 11'/><path d='M6 15h12'/><path d='M9 19h6'/>",
    blow_dry:
      "<path d='M4 10h11a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v2z'/><path d='M17 10h3v4h-3z'/><path d='M8 6V4a2.5 2.5 0 0 1 5 0v2'/>",
    hairstyling:
      "<path d='M7 4h10v2.5H7z'/><path d='M9 6.5v14M15 6.5v14'/><path d='M10 6.5h4'/>",
    hair_wash:
      "<path d='M9 4h6v2.5H9z'/><path d='M10.5 9.5c0 2.5 1 4.5 3.5 4.5s3.5-2 3.5-4.5'/><path d='M8 18.5h8'/>",
    kids_haircut:
      "<circle cx='9' cy='10' r='1.25'/><circle cx='15' cy='10' r='1.25'/><path d='M8.5 15.5c.8 1.2 2.2 2 3.5 2s2.7-.8 3.5-2'/>",
    hot_towel_shave:
      "<path d='M6 9h12v9H6z'/><path d='M8 6h8l-1 3H9l-1-3z'/><path d='M10 12h4'/>",
    hair_treatment:
      "<path d='M10 3h4v16h-4z'/><path d='M11 7h2'/><path d='M12 11v5'/><path d='M10.5 19h3'/>",
    manicure:
      "<path d='M8 5h8v14H8z'/><path d='M10 3.5V5M14 3.5V5'/><path d='M12 10v5'/>",
    gel_nails:
      "<path d='M8 6h8v12H8z'/><path d='M10 9l1.5 2 1.5-2 1.5 2 1.5-2'/>",
    nail_extensions:
      "<path d='M9 6h4v12H9z'/><path d='M13 7h3.5v10H13z'/>",
    pedicure:
      "<path d='M7 15c1.5-1 3.5-1.5 5-1.5s3.5.5 5 1.5'/><path d='M9.5 11h5'/><path d='M10 7h4v2h-4z'/>",
    nail_art:
      "<path d='M8 7h8v10H8z'/><path d='M12 7v4M10.5 11h3'/>",
    waxing:
      "<path d='M7 8 13 14'/><path d='M14 7l3 4-2 2-3-4z'/>",
    facial_wax:
      "<circle cx='12' cy='10' r='3'/><path d='M8.5 16.5c1-1.5 6-1.5 7 0'/>",
    eyebrow_shaping:
      "<path d='M5.5 12c2-2.5 5-3.5 7-3.5s5 1 7 3.5'/><path d='M8 14.5h8'/>",
    eyebrow_tint:
      "<path d='M5.5 12c2-2.5 5-3.5 7-3.5s5 1 7 3.5'/><path d='M15.5 9.5 17.5 13.5 15 15.5z'/>",
    eyelash_extensions:
      "<path d='M3.5 12s3.5-5.5 8.5-5.5 8.5 5.5 8.5 5.5-3.5-5.5-8.5-5.5S3.5 12 3.5 12z'/><circle cx='12' cy='12' r='1.75'/>",
    lash_lift:
      "<path d='M4 14c2-1.5 4.5-2 8-2s6 .5 8 2'/><path d='M8 10l4-3 4 3'/>",
    makeup:
      "<path d='M5 20 12 4l7 16'/><path d='M8.5 14h7'/>",
    massage:
      "<path d='M7.5 12a4.5 4.5 0 0 1 9 0v1.5H7.5z'/><path d='M10 18.5h4'/><path d='M12 14.5v4'/>",
    relaxing_massage:
      "<path d='M12 6.5c-1.8 1.8-2.8 3.8-2.8 6 0 3.3 1.2 5.5 2.8 5.5s2.8-2.2 2.8-5.5c0-2.2-1-4.2-2.8-6z'/><path d='M8 19h8'/>",
    deep_tissue_massage:
      "<path d='M7 11h4v8H7zM13 11h4v8h-4z'/><path d='M12 5.5v3'/>",
    aromatherapy_massage:
      "<path d='M10 4h4v14h-4z'/><path d='M12 3c-1.2 1.8-2 3.2-2 4.2a2 2 0 0 0 4 0c0-1-.8-2.4-2-4.2z'/>",
    anti_cellulite_massage:
      "<path d='M10.5 6h3v12h-3z'/><path d='M8.5 10h1.5M14 10H16M8.5 14h1.5M14 14H16'/>",
    detox_massage:
      "<path d='M12 5v2'/><path d='M9.5 9.5c0 2.5 2 4.5 2.5 4.5s2.5-2 2.5-4.5'/>",
    facial_treatment:
      "<circle cx='12' cy='10' r='3.25'/><path d='M7.5 17.5c1.2-2 8.8-2 10 0'/><path d='M9.5 8l1 1M14.5 8l-1 1'/>",
    spa_treatment:
      "<path d='M7.5 16c1.2-.8 2.5-1.2 4.5-1.2s3.3.4 4.5 1.2'/><path d='M9.5 12.5c.8-1.2 1.8-1.8 2.5-1.8s1.7.6 2.5 1.8'/>",
    body_scrub:
      "<path d='M10.5 6h3v12h-3z'/><path d='M8.5 10h1M15.5 10h-1M8.5 14h1M15.5 14h-1'/>",
    body_wrap:
      "<path d='M9.5 5.5h5v13h-5z'/><path d='M10.5 9h3M10.5 12h3M10.5 15h3'/>",
    reflexology:
      "<path d='M8 15c1.8-1 3.7-1.5 4-1.5s2.2.5 4 1.5'/><circle cx='12' cy='11.5' r='1.25'/>",
    paraffin_treatment:
      "<path d='M7.5 10.5h9v8.5h-9z'/><path d='M9.5 6.5h5v4h-5z'/>",
    dentist_consultation:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/>",
    dental_check_up:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><circle cx='16.5' cy='8' r='2.75'/><path d='M16.5 6.5v3M15 8h3'/>",
    teeth_whitening:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><path d='M12 3v1.5M17.5 4.5l.9.9M6.6 4.5l-.9.9'/>",
    dental_cleaning:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><circle cx='8.5' cy='18' r='.9'/><circle cx='12' cy='18.8' r='.9'/><circle cx='15.5' cy='18' r='.9'/>",
    tooth_filling:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><path d='M10.5 9.5h3v2.5h-3z'/>",
    root_canal_treatment:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><path d='M12 11.5v5'/>",
    dental_crown:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><path d='M9.5 5.5h5v2.5H9.5z'/>",
    dental_implant:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><path d='M12 17.5v2.5'/><path d='M10.5 20h3'/>",
    braces_orthodontics:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><path d='M8.5 10h7M8.5 13h7'/>",
    teeth_extraction:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><path d='M12 4.5l1.8-1.5M12 4.5l-1.8-1.5'/>",
    kids_dentistry:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><path d='M9.5 12h.01M14.5 12h.01'/>",
    dental_x_ray:
      "<path d='M12 4.5c-2.2 2-3.8 4.2-3.8 6.8a3.8 3.8 0 0 0 7.6 0c0-2.6-1.6-4.8-3.8-6.8z'/><rect x='4.5' y='4.5' width='15' height='15' rx='2'/>",
    personal_training:
      "<path d='M4.5 10.5h5.5v8.5H4.5zM14 9h5.5v10H14z'/><path d='M7 9V7M17 7v2'/>",
    yoga:
      "<circle cx='12' cy='6.5' r='2'/><path d='M6.5 19.5c2.2-3.5 8.8-3.5 11 0'/><path d='M9.5 13h5'/>",
    pilates:
      "<path d='M5.5 16.5h13'/><path d='M8.5 12.5 12 8.5l3.5 4'/><path d='M12 8.5v8'/>",
    swimming:
      "<path d='M3.5 14.5c2-.8 4-.8 6 0s4 .8 6 0 4-.8 6 0'/><path d='M8 8.5c1 .8 2 .8 4 0'/>",
    sauna:
      "<path d='M6.5 14.5h11v4.5H6.5z'/><path d='M8.5 10.5h7'/><path d='M10.5 6.5h3v4h-3z'/>",
    fitness:
      "<path d='M6.5 17.5 9.5 11.5l2.5 2.5 2.5-5 2.5 8.5'/>",
    physical_therapy:
      "<path d='M8.5 6.5v12M15.5 6.5v12'/><path d='M10.5 10.5h3M8.5 14.5h7'/>",
    solar_therapy:
      "<circle cx='12' cy='12' r='3.75'/><path d='M12 3v1.75M12 19.25V21M4.75 4.75l1.2 1.2M18.05 18.05l1.2 1.2M3 12h1.75M19.25 12H21'/>",
    acupuncture:
      "<path d='M8.5 4.5v15M15.5 4.5v15M12 8.5v7'/>",
    chiropractic:
      "<path d='M12 4.5v15'/><path d='M8.5 8.5h7M8.5 12h7M8.5 15.5h7'/>",
    body_sculpting:
      "<path d='M10.5 5.5h3v13h-3z'/><path d='M8.5 9.5h1.5M14 9.5h-1.5M8.5 14.5h1.5M14 14.5h-1.5'/>",
    weight_loss_program:
      "<rect x='5.5' y='6.5' width='13' height='11' rx='2'/><path d='M8.5 15.5h7M10.5 12h3'/>"
  };
