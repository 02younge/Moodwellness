/* Small hash router for GitHub Pages: each route shows only its own content. */
const MW_PAGES={home:{title:'무드웰니스',sections:['home'],nav:'home'},intro:{title:'우리의 가치',sections:['intro','matching'],nav:'intro'},core:{title:'프로그램 소개',sections:['core'],nav:'core'},private:{title:'개인·프라이빗 레슨',sections:['private'],nav:'core'},crew:{title:'정규 크루·시간표',sections:['crew'],nav:'core'},oneday:{title:'원데이클래스',sections:['oneday'],nav:'core'},teachers:{title:'강사진',sections:['teachers'],nav:'teachers'},'mw-finder':{title:'맞춤 클래스 찾기',sections:['mw-finder'],nav:'mw-finder'},rules:{title:'이용 안내',sections:['rules'],nav:'rules'},contact:{title:'문의·오시는 길',sections:['contact'],nav:'contact'}};
let mwCurrentPage=null;
function renderPage(){
 const raw=location.hash.slice(1)||'home';
 const key=raw.startsWith('teacher/')?'teachers':raw==='oneday-inquiry'||raw==='oneday-classes'?'oneday':raw==='mw-spa'?'core':raw==='matching'||raw==='approach'?'intro':Object.hasOwn(MW_PAGES,raw)?raw:'home';
 const page=MW_PAGES[key],changed=key!==mwCurrentPage;mwCurrentPage=key;
 document.querySelectorAll('main > [data-page]').forEach(node=>{const active=page.sections.includes(node.dataset.page);node.hidden=!active;node.classList.toggle('is-active',active);});
 document.querySelectorAll('.header > nav a').forEach(a=>{if(a.hash==='#'+page.nav)a.setAttribute('aria-current','page');else a.removeAttribute('aria-current');});
 document.querySelectorAll('.mw-program-nav a').forEach(a=>{if(a.hash==='#'+key)a.setAttribute('aria-current','page');else a.removeAttribute('aria-current');});
 document.title=key==='home'?'무드웰니스 | 나에게 맞는 움직임과 회복':page.title+' | 무드웰니스';
 if(changed){document.querySelectorAll('.mw-dialog[open]').forEach(d=>d.close());const main=document.getElementById('mw-main');main.focus({preventScroll:true});}
 requestAnimationFrame(()=>{if(raw==='oneday-inquiry')showOnedayRequest();else if(raw==='oneday-classes'){const heading=document.getElementById('oneday-classes');heading.focus({preventScroll:true});heading.scrollIntoView({block:'start'});}else if(raw==='mw-spa')document.getElementById('mw-spa').scrollIntoView({behavior:'instant',block:'start'});else if(raw==='matching')document.getElementById('matching').scrollIntoView({behavior:'instant',block:'start'});else if(changed)window.scrollTo({top:0,behavior:'instant'});});
}
window.addEventListener('DOMContentLoaded',()=>{renderPage();window.addEventListener('hashchange',renderPage);});
