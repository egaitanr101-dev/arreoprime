/* Nuestra empresa: misión y visión de Grupo CIISA, misión de Distribución y Transportes y valores
 * organizacionales (C·I·I·S·A). Contenido tomado del material corporativo; visible para todos los usuarios. */
(function () {
  'use strict';
  const ico = APD.icon;

  const VALORES = [
    ['C', 'Compromiso', 'Excedemos las expectativas', 'v-navy'],
    ['I', 'Integridad', 'Hacemos lo correcto', 'v-azul'],
    ['I', 'Innovación', 'Nos adaptamos para mejorar', 'v-violeta'],
    ['S', 'Simplicidad', 'Nos enfocamos en lo que agrega valor', 'v-naranja'],
    ['A', 'Agilidad', 'Ejecutamos oportunamente', 'v-oro']
  ];
  const PILARES = [
    ['stopwatch', 'Eficiencia', 'Operación eficiente, al menor costo posible.'],
    ['package', 'Entrega', 'La cantidad y calidad requeridas, con frescura e inocuidad.'],
    ['handshake', 'Servicio', 'Calidad, frescura y servicio en una operación responsable.']
  ];

  function render(el) {
    APD.app.titulo('Nuestra empresa');
    el.innerHTML = '<div class="page wide empresa">' +
      '<div class="page-head page-hero"><div><p class="eyebrow">Grupo CIISA · El Arreo</p><h2>Nuestra empresa</h2>' +
      '<p class="muted">Misión, visión y valores que guían el trabajo de Distribución y Transportes.</p></div></div>' +

      '<div class="mv-grid">' +
      '<section class="mv-card mv-mision"><span class="mv-tag">Nuestra misión</span><p class="mv-texto">Alimentamos el crecimiento <b>para una vida mejor</b></p></section>' +
      '<section class="mv-card mv-vision"><span class="mv-tag">Nuestra visión</span><p class="mv-texto">Ser los <b>preferidos</b></p></section>' +
      '</div>' +

      '<section class="card mision-dt"><div class="mision-dt-head"><span class="eyebrow">Misión</span><h3>Distribución y Transportes</h3></div>' +
      '<p class="mision-dt-texto">Entregar productos con <b>calidad, frescura y servicio</b>, asegurando la cantidad y calidad requeridas, al menor costo posible, mediante una operación eficiente y responsable que cumpla estrictamente con los <b>estándares de inocuidad</b>.</p>' +
      '<ul class="pilares">' + PILARES.map(p => '<li><span class="pilar-ico" aria-hidden="true">' + ico(p[0], 30) + '</span><b>' + p[1] + '</b><small>' + p[2] + '</small></li>').join('') + '</ul></section>' +

      '<section class="card valores"><div class="card-head"><h3>' + ico('shield-check', 18) + ' Nuestros valores organizacionales</h3><span class="valores-sigla" aria-label="C I I S A">C·I·I·S·A</span></div>' +
      '<ul class="valores-lista">' + VALORES.map(v => '<li class="valor ' + v[3] + '"><span class="valor-letra" aria-hidden="true"><i>' + v[0] + '</i></span>' +
        '<span class="valor-txt"><b>' + v[1] + '</b><small>' + v[2] + '</small></span></li>').join('') + '</ul></section>' +
      '</div>';
  }

  APD.pages.empresa = { render };
})();
